// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

struct PreparedTileCacheIdentity {
    let preparedFormatVersion: UInt32
    let styleRevision: UInt32
    let tileSourceRevision: UInt64
    let flatSeparateRoadRenderingMinimumZoom: UInt32
    let textRevision: UInt32
    let labelLanguage: ImmersiveMapSettings.LabelLanguage
    let labelFallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy
    let houseNumbersEnabled: Bool
    let houseNumbersMinimumZoom: UInt32
    let capitalMaximumZoom: UInt32
    let cityMaximumZoom: UInt32
    let smallSettlementMaximumZoom: UInt32
    let landmarkMinimumZoom: UInt32
    let addTestBorders: Bool

    var namespaceComponent: String {
        "s\(styleRevision)-u\(String(tileSourceRevision, radix: 16))-r\(flatSeparateRoadRenderingMinimumZoom)-t\(textRevision)-l\(labelLanguage.preparedTileCacheNamespaceKey)-f\(labelFallbackPolicy.rawValue)-h\(houseNumbersEnabled ? 1 : 0)-z\(houseNumbersMinimumZoom)-c\(capitalMaximumZoom)-y\(cityMaximumZoom)-m\(smallSettlementMaximumZoom)-k\(landmarkMinimumZoom)-b\(addTestBorders ? 1 : 0)"
    }

    static func tileSourceRevision(for network: ImmersiveMapSettings.TileSettings.NetworkSettings) -> UInt64 {
        var hasher = StableFNV1aHasher()
        hasher.combine(network.tileBaseURL.absoluteString)
        hasher.combine(String(network.cacheIdentity))
        switch network.authorizationMode {
        case .bearerHeader:
            hasher.combine("bearerHeader")
        case .accessTokenQuery(let parameterName):
            hasher.combine("accessTokenQuery:\(parameterName)")
        }
        return hasher.finalize()
    }
}

final class PreparedTileDiskCaching {
    static let preparedFormatVersion: UInt32 = 21

    private let cacheRootDirectory: URL
    private let cacheDirectory: URL
    private let cacheDuration: TimeInterval
    private let cacheIdentity: PreparedTileCacheIdentity
    private let fileManager: FileManager

    init(config: ImmersiveMapSettings,
         cacheIdentity: PreparedTileCacheIdentity,
         fileManager: FileManager = .default,
         baseCachesDirectory: URL? = nil) {
        self.cacheDuration = config.tiles.cache.preparedDiskTimeToLive
        self.cacheIdentity = cacheIdentity
        self.fileManager = fileManager

        let cachesDirectory = baseCachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheRootDirectory = cachesDirectory.appendingPathComponent("MapPreparedTiles")
        self.cacheDirectory = cacheRootDirectory
            .appendingPathComponent("v\(cacheIdentity.preparedFormatVersion)")
            .appendingPathComponent(cacheIdentity.namespaceComponent)

        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            #if DEBUG
            print("Failed to create prepared tile cache directory: \(error)")
            #endif
        }

        if config.tiles.cache.clearDiskCachesOnLaunch {
            do {
                try clearAllCache()
            } catch {
                #if DEBUG
                print("Failed to clear prepared tile cache: \(error)")
                #endif
            }
        }
    }

    /// Loads the cached prepared tile. When `matchingETag` is non-nil the entry is
    /// returned only if it was derived from that exact raw-tile ETag (content-fresh
    /// reuse); nil accepts any cached entry regardless of ETag (offline fallback).
    func requestPreparedDiskCached(tile: Tile, matchingETag: String?) async -> PreparedTileCPU? {
        let cachePath = cachePathFor(tile: tile)
        guard let data = loadCachedFile(at: cachePath) else {
            return nil
        }

        do {
            return try PreparedTileDiskCodec.decode(data: data,
                                                    expectedTile: tile,
                                                    cacheIdentity: cacheIdentity,
                                                    expectedSourceETag: matchingETag)
        } catch PreparedTileDiskCodecError.invalidMetadata {
            // Benign identity/ETag mismatch (e.g. the raw tile's ETag changed): keep
            // the file. A fresh parse overwrites it atomically, and meanwhile it stays
            // available for the offline fallback. Deleting here would risk a rendering
            // hole if the load is cancelled before the re-save.
            return nil
        } catch {
            // Genuine corruption / unreadable payload: evict it.
            removeFromDisk(tile: tile)
            return nil
        }
    }

    func saveOnDisk(tile: Tile, preparedTile: PreparedTileCPU, sourceETag: String?) {
        guard preparedTile.tile == tile else {
            return
        }
        let cachePath = cachePathFor(tile: tile)
        do {
            let data = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                        cacheIdentity: cacheIdentity,
                                                        sourceETag: sourceETag ?? "")
            try saveToCache(data: data, for: cachePath)
        } catch {
            #if DEBUG
            print("Failed to save prepared tile to \(cachePath.path): \(error)")
            #endif
        }
    }

    func removeFromDisk(tile: Tile) {
        let cachePath = cachePathFor(tile: tile)
        do {
            try fileManager.removeItem(at: cachePath)
        } catch {
            // Best-effort removal for corrupted or obsolete prepared entries.
        }
    }

    func clearAllCache() throws {
        if fileManager.fileExists(atPath: cacheRootDirectory.path) {
            try fileManager.removeItem(at: cacheRootDirectory)
        }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func cachePathFor(tile: Tile) -> URL {
        let fileName = "\(tile.z)_\(tile.x)_\(tile.y).ptile"
        return cacheDirectory.appendingPathComponent(fileName)
    }

    private func saveToCache(data: Data, for cachePath: URL) throws {
        let directory = cachePath.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: cachePath, options: .atomic)
    }

    private func loadCachedFile(at cachePath: URL) -> Data? {
        guard fileManager.fileExists(atPath: cachePath.path) else {
            return nil
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: cachePath.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            removeFileBestEffort(at: cachePath)
            return nil
        }

        if Date().timeIntervalSince(modificationDate) > cacheDuration {
            removeFileBestEffort(at: cachePath)
            return nil
        }

        do {
            return try Data(contentsOf: cachePath)
        } catch {
            removeFileBestEffort(at: cachePath)
            return nil
        }
    }

    private func removeFileBestEffort(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}
