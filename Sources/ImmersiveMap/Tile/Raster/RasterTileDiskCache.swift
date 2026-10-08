// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The raster tiles on disk. A raster tile is made from its prepared tile,
/// so it lives in that tile's namespace, in a directory per texture size
/// and fade zoom (`raster-v<format>-<size>-z<fade zoom>` inside the
/// prepared namespace directory),
/// and goes with it: a new style, a new tile source or a new prepared
/// format is a new namespace, and the raster tiles of the old one age out
/// with its prepared tiles. The files are written and pruned through the
/// prepared cache's IO coordinator, so they count against its quota and
/// its TTL.
///
/// A file is the texture's levels as `RasterTileLayout` packs them. Where
/// the prepared tiles keep their geometry in files the IO queue loads (a
/// Metal 3 device), the raster tiles are written the same way, an MTLIO
/// compression container or the raw bytes as the prepared geometry is, and
/// the IO queue loads a file level by level into the texture. Elsewhere
/// the file is the raw bytes, read back and copied into the texture.
///
/// Thread-safe (`@unchecked Sendable`): the file work runs on the
/// coordinator's queue, and the per-size indexes are behind `lock`.
final class RasterTileDiskCache: @unchecked Sendable {
    /// What a raster tile file holds. A change to the bake (what is drawn,
    /// how, in which format) is a new number, so a cache written by an
    /// older build is never read as this one's.
    // 2: the zoom fades are evaluated at the key's fade zoom, a faded-out
    // fill left out. A v1 texture carries every fill at its full alpha.
    static let formatVersion = 2

    /// How the files of this session are stored, and so how they load.
    enum FileFormat: Equatable {
        /// Read back and copied into the texture.
        case plain
        /// Loaded into the texture by the IO queue, from the container
        /// format the prepared geometry uses.
        case ioQueue(PreparedTileFileBlobFormat)
    }

    let fileFormat: FileFormat

    private let namespaceDirectory: URL
    private let coordinator: PreparedTileDiskIOCoordinator
    private let geometryTransport: any PreparedTileGeometryTransporting
    private let timeToLive: TimeInterval
    private let lock = NSLock()
    /// A directory's index and whether it is read, by size and fade zoom.
    private struct DirectoryKey: Hashable {
        let size: Int
        let fadeZoom: Int
    }
    private var indexesByDirectory: [DirectoryKey: PreparedTileAvailabilityIndex] = [:]
    private var readyDirectories: Set<DirectoryKey> = []
    private var indexReadyHandler: (@Sendable () -> Void)?

    init(config: ImmersiveMapSettings,
         cacheIdentity: PreparedTileCacheIdentity,
         geometryTransport: any PreparedTileGeometryTransporting,
         fileManager: FileManager = .default,
         baseCachesDirectory: URL? = nil) {
        let rootDirectory = PreparedTileDiskCaching.rootDirectory(fileManager: fileManager,
                                                                  baseCachesDirectory: baseCachesDirectory)
        self.namespaceDirectory = PreparedTileDiskCaching.namespaceDirectory(rootDirectory: rootDirectory,
                                                                             cacheIdentity: cacheIdentity,
                                                                             geometryTransport: geometryTransport)
        self.coordinator = PreparedTileDiskIOCoordinator.shared(rootDirectory: rootDirectory, fileManager: fileManager)
        self.geometryTransport = geometryTransport
        self.timeToLive = config.tiles.cache.preparedDiskTimeToLive
        switch geometryTransport.blobTransport {
        case .inline:
            self.fileFormat = .plain
        case .file(let format):
            self.fileFormat = .ioQueue(format)
        }
    }

    /// The directory of one texture size and fade zoom.
    func directory(size: Int, fadeZoom: Int) -> URL {
        namespaceDirectory.appendingPathComponent("raster-v\(Self.formatVersion)-\(size)-z\(fadeZoom)")
    }

    func fileURL(for key: RasterTileKey) -> URL {
        directory(size: key.size, fadeZoom: key.fadeZoom).appendingPathComponent("\(key.tile.z)_\(key.tile.x)_\(key.tile.y).ptraster")
    }

    /// What the index says of a tile's file.
    enum Presence {
        /// The directory's index is still being read from the disk: the answer
        /// comes with the frame `onIndexReady` asks for.
        case unknown
        case present
        case absent
    }

    /// Called once a directory's index is read, off the main thread: the frame
    /// that asked before then gets its answer from the next one.
    var onIndexReady: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return indexReadyHandler
        }
        set {
            lock.lock()
            indexReadyHandler = newValue
            lock.unlock()
        }
    }

    /// Whether the tile's file is on disk and unexpired: a lock-only read,
    /// safe on the frame path. A hint, as the prepared index is: a file
    /// that turns out unreadable is removed and the tile baked again.
    func presence(of key: RasterTileKey) -> Presence {
        let (index, isReady) = index(for: key)
        guard isReady else { return .unknown }
        return index.contains(key.tile) ? .present : .absent
    }

    /// Refreshes the file's access time, which is its place in the LRU
    /// prune and its TTL.
    func markAccessed(_ key: RasterTileKey) {
        let url = fileURL(for: key)
        coordinator.enqueue { [coordinator] in
            coordinator.markAccessed(url)
        }
    }

    /// Out of the index at once, so the next frame bakes the tile instead
    /// of loading the file again, and off the disk on the queue.
    func remove(_ key: RasterTileKey) {
        index(for: key).index.remove(key.tile)
        let url = fileURL(for: key)
        coordinator.enqueue { [coordinator] in
            coordinator.removeFile(at: url)
        }
    }

    /// The file's bytes, for the plain format. Nil when the file is gone,
    /// expired or not the size a texture of its key takes.
    func readBytes(for key: RasterTileKey) async -> Data? {
        let url = fileURL(for: key)
        let expectedByteCount = RasterTileLayout.totalByteCount(size: key.size)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            coordinator.enqueue { [coordinator] in
                guard let data = coordinator.readFile(at: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard data.count == expectedByteCount else {
                    coordinator.removeFile(at: url)
                    continuation.resume(returning: nil)
                    return
                }
                coordinator.markAccessed(url)
                continuation.resume(returning: data)
            }
        }
    }

    /// Writes a baked texture's bytes. The container is staged on the
    /// calling thread (it may compress), the swap into place and the quota
    /// accounting run on the coordinator's queue.
    func save(_ bytes: Data, for key: RasterTileKey) {
        let url = fileURL(for: key)
        switch fileFormat {
        case .plain:
            coordinator.enqueue { [coordinator] in
                do {
                    try coordinator.writeFile(bytes, to: url)
                } catch {
#if DEBUG
                    print("Failed to save raster tile to \(url.path): \(error)")
#endif
                }
            }
        case .ioQueue:
            let stagedURL: URL
            do {
                stagedURL = try geometryTransport.stageBlobFile(bytes, near: url)
            } catch {
#if DEBUG
                print("Failed to stage raster tile for \(key.tile): \(error)")
#endif
                return
            }
            coordinator.enqueue { [coordinator, geometryTransport] in
                do {
                    try geometryTransport.commitStagedBlobFile(at: stagedURL, to: url)
                    coordinator.registerWrittenFile(at: url)
                } catch {
#if DEBUG
                    print("Failed to save raster tile to \(url.path): \(error)")
#endif
                }
            }
        }
    }

    /// The availability index of a key's directory, made and seeded on
    /// first use, and whether the seed has run. The seed is enqueued behind
    /// the prepared cache's own preparation, which the first frame follows.
    private func index(for key: RasterTileKey) -> (index: PreparedTileAvailabilityIndex, isReady: Bool) {
        let directoryKey = DirectoryKey(size: key.size, fadeZoom: key.fadeZoom)
        lock.lock()
        if let index = indexesByDirectory[directoryKey] {
            let isReady = readyDirectories.contains(directoryKey)
            lock.unlock()
            return (index, isReady)
        }
        let directory = directory(size: key.size, fadeZoom: key.fadeZoom)
        let index = coordinator.availabilityIndex(forDirectory: directory, timeToLive: timeToLive)
        indexesByDirectory[directoryKey] = index
        lock.unlock()
        let timeToLive = timeToLive
        coordinator.enqueue { [weak self, coordinator] in
            coordinator.prepareAuxiliaryDirectory(directory, timeToLive: timeToLive)
            guard let self else { return }
            self.lock.lock()
            self.readyDirectories.insert(directoryKey)
            let onIndexReady = self.indexReadyHandler
            self.lock.unlock()
            onIndexReady?()
        }
        return (index, false)
    }
}
