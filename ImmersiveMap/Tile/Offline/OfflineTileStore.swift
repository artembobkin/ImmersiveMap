// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Persisted description of one downloaded region: the region itself plus the
/// progress counters of its last download run, so a relaunch can show status
/// without walking the tile files.
struct OfflineStoredRegionRecord: Codable, Equatable, Sendable {
    var region: ImmersiveMapOfflineRegion
    var createdAt: Date
    var isComplete: Bool
    var storedTileCount: Int
    var failedTileCount: Int
    var byteCount: Int64
    var wasBlockedByAuthorization: Bool
}

/// On-disk home of downloaded tiles, namespaced by the tile source the bytes
/// came from (`PreparedTileCacheIdentity.tileSourceRevision`, the same hash
/// that keys the prepared-tile cache), so a map view and a standalone
/// `ImmersiveMapOfflineController` configured with the same provider agree on
/// the location without ever meeting.
///
/// Lives in Application Support rather than Caches: a region is an explicit
/// download the user expects to keep, not something the OS may evict under
/// storage pressure. Removal is the app's (or the controller's) job.
///
/// Layout: `<base>/ImmersiveMapOfflineTiles/v1/u<source-hex>/`
///   - `regions/<fnv64(id)>.json` for region records
///   - `tiles/z<z>/<x>_<y>.mvt` for raw tile bytes; a zero-byte file records a
///     tile the source reported as empty (HTTP 404/410 or an empty body), so
///     resuming a download does not refetch it and offline serving can answer
///     "known empty" instead of "unknown".
///
/// All writes are atomic single-file operations and every method touches the
/// filesystem directly with no in-memory state, so the value is freely usable
/// from concurrent tasks; readers of a tile see it fully written or absent.
struct OfflineTileStore: Sendable {
    static let formatVersion = 1

    let rootDirectory: URL

    private var regionsDirectory: URL {
        rootDirectory.appendingPathComponent("regions", isDirectory: true)
    }

    private var tilesDirectory: URL {
        rootDirectory.appendingPathComponent("tiles", isDirectory: true)
    }

    init(network: ImmersiveMapSettings.TileSettings.NetworkSettings,
         baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sourceRevision = PreparedTileCacheIdentity.tileSourceRevision(for: network)
        self.rootDirectory = base
            .appendingPathComponent("ImmersiveMapOfflineTiles", isDirectory: true)
            .appendingPathComponent("v\(Self.formatVersion)", isDirectory: true)
            .appendingPathComponent("u\(String(sourceRevision, radix: 16))", isDirectory: true)
    }

    // MARK: - Tiles

    /// Raw tile bytes, `Data()` for a known-empty tile, `nil` when the store
    /// has never seen the tile.
    func tileData(for tile: Tile) -> Data? {
        try? Data(contentsOf: tileFileURL(for: tile), options: .mappedIfSafe)
    }

    func containsTile(_ tile: Tile) -> Bool {
        FileManager.default.fileExists(atPath: tileFileURL(for: tile).path)
    }

    /// Size of the stored tile file, `nil` when absent. Zero means the tile is
    /// stored as known empty.
    func storedByteCount(of tile: Tile) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: tileFileURL(for: tile).path)
        guard let size = attributes?[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    func writeTile(_ tile: Tile, data: Data) throws {
        let fileURL = tileFileURL(for: tile)
        try ensureDirectoryExists(fileURL.deletingLastPathComponent())
        try data.write(to: fileURL, options: .atomic)
    }

    func writeEmptyTileMarker(_ tile: Tile) throws {
        try writeTile(tile, data: Data())
    }

    /// The stored tile translated into the loader's download vocabulary:
    /// bytes become a successful download, a known-empty marker becomes
    /// `.notFound` (the loader then applies its long not-found cooldown
    /// instead of hammering a tile that has nothing to render), absence is
    /// `nil` so the caller can fall through to its own failure.
    func downloadResult(for tile: Tile) -> TileDownloader.DownloadResult? {
        guard let data = tileData(for: tile) else {
            return nil
        }
        guard data.isEmpty == false else {
            return .failure(.notFound)
        }
        return .success(data, etag: nil)
    }

    /// Deletes every stored tile that is not in `tiles`, returning the number
    /// of files removed. Region removal computes `tiles` as the union of the
    /// remaining regions, so tiles shared with another region survive.
    @discardableResult
    func pruneTiles(keeping tiles: Set<Tile>) -> Int {
        let fileManager = FileManager.default
        guard let zoomDirectories = try? fileManager.contentsOfDirectory(at: tilesDirectory,
                                                                         includingPropertiesForKeys: nil) else {
            return 0
        }
        var removedCount = 0
        for zoomDirectory in zoomDirectories {
            guard let zoom = Int(zoomDirectory.lastPathComponent.dropFirst()),
                  zoomDirectory.lastPathComponent.hasPrefix("z"),
                  let files = try? fileManager.contentsOfDirectory(at: zoomDirectory,
                                                                   includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                let parts = name.split(separator: "_")
                guard parts.count == 2,
                      let x = Int(parts[0]),
                      let y = Int(parts[1]) else {
                    continue
                }
                if tiles.contains(Tile(x: x, y: y, z: zoom)) == false {
                    try? fileManager.removeItem(at: file)
                    removedCount += 1
                }
            }
            if let remaining = try? fileManager.contentsOfDirectory(atPath: zoomDirectory.path),
               remaining.isEmpty {
                try? fileManager.removeItem(at: zoomDirectory)
            }
        }
        return removedCount
    }

    /// Counts how many of the given tiles are stored and how many bytes they
    /// occupy. Used to rebuild accurate progress for a region whose download
    /// was interrupted without a final record write.
    func measureStoredTiles(of tiles: [Tile]) -> (storedTileCount: Int, byteCount: Int64) {
        var storedTileCount = 0
        var byteCount: Int64 = 0
        for tile in tiles {
            if let size = storedByteCount(of: tile) {
                storedTileCount += 1
                byteCount += size
            }
        }
        return (storedTileCount, byteCount)
    }

    // MARK: - Region records

    func regionRecords() -> [OfflineStoredRegionRecord] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: regionsDirectory,
                                                               includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else {
                    return nil
                }
                return try? decoder.decode(OfflineStoredRegionRecord.self, from: data)
            }
            .sorted { $0.region.id < $1.region.id }
    }

    func writeRegionRecord(_ record: OfflineStoredRegionRecord) throws {
        try ensureDirectoryExists(regionsDirectory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: regionFileURL(id: record.region.id), options: .atomic)
    }

    func removeRegionRecord(id: String) {
        try? FileManager.default.removeItem(at: regionFileURL(id: id))
    }

    /// Removes the whole namespace: every region record and every tile of
    /// this tile source.
    func removeEverything() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - Paths

    private func tileFileURL(for tile: Tile) -> URL {
        tilesDirectory
            .appendingPathComponent("z\(tile.z)", isDirectory: true)
            .appendingPathComponent("\(tile.x)_\(tile.y).mvt")
    }

    private func regionFileURL(id: String) -> URL {
        var hasher = StableFNV1aHasher()
        hasher.combine(id)
        return regionsDirectory.appendingPathComponent("\(String(hasher.finalize(), radix: 16)).json")
    }

    private func ensureDirectoryExists(_ directory: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Concurrent downloads race on creating the same zoom directory;
            // losing that race is success as long as the directory exists.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw error
            }
        }
    }
}
