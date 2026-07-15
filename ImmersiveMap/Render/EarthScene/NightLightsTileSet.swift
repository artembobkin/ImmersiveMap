// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct NightLightsTileMapping: Equatable {
    let tile: Tile
    let uvOrigin: SIMD2<Float>
    let uvScale: SIMD2<Float>
}

final class NightLightsTileSet {
    struct Metadata: Codable, Equatable {
        let version: Int
        let format: String
        let tileSize: Int
        let minZoom: Int
        let maxZoom: Int
        let source: String
        let attribution: String
        let tileURLTemplate: String?

        init(version: Int,
             format: String,
             tileSize: Int,
             minZoom: Int,
             maxZoom: Int,
             source: String,
             attribution: String,
             tileURLTemplate: String? = nil) {
            self.version = version
            self.format = format
            self.tileSize = tileSize
            self.minZoom = minZoom
            self.maxZoom = maxZoom
            self.source = source
            self.attribution = attribution
            self.tileURLTemplate = tileURLTemplate
        }
    }

    let metadata: Metadata

    init(metadata: Metadata) {
        self.metadata = metadata
    }

    func bestAvailableTile(for tile: Tile) -> Tile {
        if tile.z < metadata.minZoom {
            let zoomDifference = metadata.minZoom - tile.z
            return Tile(x: tile.x << zoomDifference,
                        y: tile.y << zoomDifference,
                        z: metadata.minZoom)
        }

        if tile.z > metadata.maxZoom, let parent = tile.findParentTile(atZoom: metadata.maxZoom) {
            return parent
        }

        return tile
    }

    func mapping(for tile: Tile) -> NightLightsTileMapping? {
        guard tile.z >= metadata.minZoom else {
            return nil
        }

        let sourceTile = bestAvailableTile(for: tile)
        guard tile.z > sourceTile.z else {
            return NightLightsTileMapping(tile: sourceTile,
                                          uvOrigin: SIMD2<Float>(0.0, 0.0),
                                          uvScale: SIMD2<Float>(1.0, 1.0))
        }

        let scale = 1 << (tile.z - sourceTile.z)
        let uvScale = 1.0 / Float(scale)
        let originX = Float(tile.x - sourceTile.x * scale) * uvScale
        let originY = Float(tile.y - sourceTile.y * scale) * uvScale

        return NightLightsTileMapping(tile: sourceTile,
                                      uvOrigin: SIMD2(originX, originY),
                                      uvScale: SIMD2(uvScale, uvScale))
    }

    func url(for tile: Tile) -> URL? {
        let sourceTile = bestAvailableTile(for: tile)
        guard let tileURLTemplate = metadata.tileURLTemplate else {
            return nil
        }

        let urlString = tileURLTemplate
            .replacingOccurrences(of: "{z}", with: String(sourceTile.z))
            .replacingOccurrences(of: "{x}", with: String(sourceTile.x))
            .replacingOccurrences(of: "{y}", with: String(sourceTile.y))
        return URL(string: urlString)
    }
}

struct NightLightsTileSetMetadataLoader: Sendable {
    private let loadData: @Sendable (URL) async throws -> Data

    init(loadData: @escaping @Sendable (URL) async throws -> Data = Self.loadData(from:)) {
        self.loadData = loadData
    }

    func load(from metadataURL: URL) async throws -> NightLightsTileSet {
        let data = try await loadData(metadataURL)
        let metadata = try JSONDecoder().decode(NightLightsTileSet.Metadata.self, from: data)
        return NightLightsTileSet(metadata: metadata)
    }

    private static func loadData(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

/// Внутренне синхронизирован: `storedTileSet` доступен только через `stateQueue`.
final class NightLightsTileSetStore: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "ImmersiveMap.NightLightsTileSetStore.state")
    private var storedTileSet: NightLightsTileSet?

    var tileSet: NightLightsTileSet? {
        stateQueue.sync {
            storedTileSet
        }
    }

    func update(_ tileSet: NightLightsTileSet?) {
        stateQueue.sync {
            storedTileSet = tileSet
        }
    }
}
