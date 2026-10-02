// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PMTiles

/// Where model tiles come from: the disk cache, and behind it the model
/// archive. A tile is requested apart from the map's own tiles, with its own
/// session, its own archive client and its own cache.
///
/// The archive is a PMTiles file like the map's, so the same client reads
/// it: the header and the directory once, then one range request per tile.
/// A tile the directory does not list costs no request, which matters here
/// because most of the map has no models. What comes back is the tile
/// decompressed, in the form the GPU takes (`ModelTileContents`), and that
/// is what the disk keeps: a tile seen before is uploaded with no network
/// and no decoding, its blocks loaded from the file straight into the GPU's
/// buffers and texture (`ModelTileMesh`).
///
/// The disk cache is keyed by the archive's URL and by the ETag the host
/// gives it. An archive may be published under one fixed name and
/// overwritten: the ETag changes with the upload, the tiles kept under the
/// old one are left behind and removed, and the map shows the new models
/// with no cache to clear. The ETag comes with the archive's header, which
/// a session reads once in any case. With no network the last ETag seen
/// stands, so the tiles on disk still serve. A host that sends no ETag, and
/// an archive read from disk, are keyed by the URL alone. A map that clears
/// its disk caches on launch clears this one too.
///
/// `@unchecked Sendable`: the archive client synchronises its own state,
/// the files are written atomically, and the one mutable property, the
/// archive version in use, goes through `lock`.
final class ModelTileSource: @unchecked Sendable {
    enum Outcome: Equatable {
        /// The tile's bytes, decompressed, and the file they are in when
        /// they came from the disk cache: the GPU's blocks are loaded
        /// straight from it, and the bytes are a mapping of it, read only
        /// as far as the tile's tables.
        case tile(Data, fileURL: URL?)
        /// The archive has no models in this tile.
        case missing
    }

    /// The version of the cache's layout on disk, part of its path.
    static let diskCacheVersion = 1
    static let rootDirectoryName = "MapModelTiles"

    /// The name of the file, in the archive's directory, that remembers
    /// the version last seen.
    static let currentVersionFileName = "current"
    /// The version of a host that sends no ETag.
    static let unversionedName = "unversioned"

    private let archive: PMTilesArchiveClient
    /// The directory of this archive's URL. The tiles of each upload of
    /// the archive are in a directory of their own under it.
    private let archiveDirectory: URL
    private let diskCacheSizeInBytes: Int
    private let lock = NSLock()
    /// The directory name of the upload in use: from the archive's ETag
    /// once a request has seen it, until then the one remembered on disk.
    private var versionName: String
    private let fileManager = FileManager.default
    private static let maintenanceQueue = DispatchQueue(label: "ImmersiveMap.ModelTileSource.maintenance",
                                                        qos: .utility)

    convenience init(settings: ImmersiveMapSettings.ModelArchiveSettings, clearsDiskCache: Bool) {
        let configuration = URLSessionConfiguration.ephemeral
        // A model tile that stops arriving for 30 s has failed for the
        // frame's purposes: the map's building stands meanwhile, and the
        // store asks again later.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        self.init(archive: PMTilesArchiveClient(archiveURL: settings.archiveURL,
                                                requestHeaders: settings.requestHeaders,
                                                session: URLSession(configuration: configuration),
                                                tileType: .unknown),
                  diskCacheSizeInBytes: settings.diskCacheSizeInBytes,
                  clearsDiskCache: clearsDiskCache)
    }

    /// The test seam: a client over whatever fetcher the test wants, and a
    /// cache root of the test's own.
    init(archive: PMTilesArchiveClient,
         diskCacheSizeInBytes: Int,
         clearsDiskCache: Bool,
         baseCachesDirectory: URL? = nil) {
        self.archive = archive
        self.diskCacheSizeInBytes = max(0, diskCacheSizeInBytes)
        let cachesDirectory = baseCachesDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let rootDirectory = cachesDirectory.appendingPathComponent(Self.rootDirectoryName)
        var hasher = StableFNV1aHasher()
        hasher.combine(archive.archiveURL.absoluteString)
        self.archiveDirectory = rootDirectory
            .appendingPathComponent("v\(Self.diskCacheVersion)")
            .appendingPathComponent(String(hasher.finalize(), radix: 16))
        if clearsDiskCache {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        let remembered = try? String(contentsOf: archiveDirectory.appendingPathComponent(Self.currentVersionFileName),
                                     encoding: .utf8)
        self.versionName = remembered.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unversionedName
        let directory = archiveDirectory.appendingPathComponent(versionName)
        let quota = self.diskCacheSizeInBytes
        Self.maintenanceQueue.async {
            Self.trim(directory: directory, toByteCount: quota)
        }
    }

    /// The tile's bytes from the disk, or from the archive and then kept on
    /// the disk. Throws what the archive client throws
    /// (`PMTilesArchiveClient.Failure`) when the archive cannot answer.
    func tileBytes(_ tile: Tile) async throws -> Outcome {
        // The archive's ETag first: it says which upload the tiles on disk
        // must be of. The client reads the header once and answers from
        // memory after that. Without an answer (no network) the version
        // remembered stands, and the disk serves what it has.
        if let etag = try? await archive.archiveETag() {
            useVersion(of: etag)
        }
        let fileURL = cacheFileURL(for: tile)
        if let cached = try? Data(contentsOf: fileURL, options: .mappedIfSafe), cached.isEmpty == false {
            // The date is what the quota trims by: the least recently read
            // go first.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return .tile(cached, fileURL: fileURL)
        }
        switch try await archive.tileBytes(z: tile.z, x: tile.x, y: tile.y) {
        case .tile(let data, _):
            guard data.isEmpty == false else {
                return .missing
            }
            store(data, at: fileURL)
            // The bytes are in memory already: they go to the GPU from
            // here, and the next session loads the file.
            return .tile(data, fileURL: nil)
        case .missing, .outsideZoomRange:
            return .missing
        }
    }

    /// Drops a cached tile whose bytes turned out not to be a tile, so the
    /// next request reads the archive again.
    func discardCachedTile(_ tile: Tile) {
        try? fileManager.removeItem(at: cacheFileURL(for: tile))
    }

    /// Where the tile is kept on disk, under the upload of the archive in
    /// use.
    func cacheFileURL(for tile: Tile) -> URL {
        cacheDirectory.appendingPathComponent("\(tile.z)-\(tile.x)-\(tile.y).immt")
    }

    private var cacheDirectory: URL {
        lock.lock()
        defer { lock.unlock() }
        return archiveDirectory.appendingPathComponent(versionName)
    }

    /// The directory name of an upload: its ETag hashed, since an ETag is
    /// not a file name. `nil` is a host that sends none.
    static func versionName(of etag: String?) -> String {
        guard let etag, etag.isEmpty == false else {
            return unversionedName
        }
        var hasher = StableFNV1aHasher()
        hasher.combine(etag)
        return String(hasher.finalize(), radix: 16)
    }

    /// Moves to the tiles of the upload `etag` names. On a change the
    /// version is remembered on disk for a session without a network, and
    /// the tiles of every other upload are removed: their archive is gone.
    private func useVersion(of etag: String?) {
        let name = Self.versionName(of: etag)
        lock.lock()
        let changed = name != versionName
        versionName = name
        lock.unlock()
        guard changed else { return }
        let directory = archiveDirectory
        Self.maintenanceQueue.async {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(name.utf8).write(to: directory.appendingPathComponent(Self.currentVersionFileName),
                                       options: .atomic)
            for entry in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            where entry != name && entry != Self.currentVersionFileName {
                try? fileManager.removeItem(at: directory.appendingPathComponent(entry))
            }
        }
    }

    private func store(_ data: Data, at fileURL: URL) {
        guard diskCacheSizeInBytes > 0 else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // The cache is an optimisation: a tile that could not be kept
            // is asked from the archive again.
        }
    }

    /// Removes the least recently read tiles until the directory fits the
    /// quota. Run once per source, off the caller's thread: a session adds
    /// to the cache far slower than the quota is sized for.
    static func trim(directory: URL, toByteCount quota: Int) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: Array(keys)) else {
            return
        }
        var entries: [(url: URL, byteCount: Int, date: Date)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), let byteCount = values.fileSize else {
                continue
            }
            entries.append((file, byteCount, values.contentModificationDate ?? .distantPast))
            total += byteCount
        }
        guard total > quota else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.byteCount
            if total <= quota {
                break
            }
        }
    }
}
