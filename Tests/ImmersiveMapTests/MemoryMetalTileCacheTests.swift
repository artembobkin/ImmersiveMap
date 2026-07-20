// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

/// Пиннинг мирового покрытия: тайлы z <= 3, однажды попав в кэш, переживают
/// обычное LRU-давление, но отпускаются при memory warning (если не видимы)
/// и при полной очистке.
final class MemoryMetalTileCacheTests: XCTestCase {
    func testPinnedWorldCoverTileSurvivesLruPressure() throws {
        let cache = makeCache()
        let pinnedTile = Tile(x: 1, y: 1, z: 3)
        cache.setTileData(tile: try makeMetalTile(pinnedTile), forKey: pinnedTile)

        let highZoomTiles = (0..<4).map { Tile(x: $0, y: 0, z: 10) }
        for tile in highZoomTiles {
            cache.setTileData(tile: try makeMetalTile(tile), forKey: tile)
        }

        XCTAssertNotNil(cache.getTile(forKey: pinnedTile),
                        "Pinned z3 тайл не должен вытесняться обычным давлением")
        XCTAssertNil(cache.getTile(forKey: highZoomTiles[0]),
                     "Старые обычные тайлы должны вытесняться при лимите 1 байт")
    }

    func testMemoryWarningDropsHiddenPinnedTile() throws {
        let cache = makeCache()
        let pinnedTile = Tile(x: 2, y: 2, z: 2)
        cache.setTileData(tile: try makeMetalTile(pinnedTile), forKey: pinnedTile)

        cache.trim(toFractionOfLimit: 0)

        XCTAssertNil(cache.getTile(forKey: pinnedTile))
    }

    func testMemoryWarningKeepsVisiblePinnedTile() throws {
        let cache = makeCache()
        let pinnedTile = Tile(x: 2, y: 2, z: 2)
        cache.setTileData(tile: try makeMetalTile(pinnedTile), forKey: pinnedTile)
        cache.updateProtectedTiles([pinnedTile])

        cache.trim(toFractionOfLimit: 0)

        XCTAssertNotNil(cache.getTile(forKey: pinnedTile))
    }

    func testRemoveAllClearsPinnedStateAndAllowsRepin() throws {
        let cache = makeCache()
        let pinnedTile = Tile(x: 0, y: 0, z: 0)
        cache.setTileData(tile: try makeMetalTile(pinnedTile), forKey: pinnedTile)

        cache.removeAll()
        XCTAssertNil(cache.getTile(forKey: pinnedTile))

        cache.setTileData(tile: try makeMetalTile(pinnedTile), forKey: pinnedTile)
        XCTAssertNotNil(cache.getTile(forKey: pinnedTile))
    }

    // Лимит 1 байт: любая вставка создаёт давление вытеснения, что позволяет
    // проверять защиту pinned-тайлов без знания фактических размеров буферов.
    private func makeCache() -> MemoryMetalTileCache {
        MemoryMetalTileCache(maxCacheSizeInBytes: 1,
                             tileTraceRecorder: TileTraceRecorder())
    }

    private func makeMetalTile(_ tile: Tile) throws -> MetalTile {
        MetalTile(tile: tile, tileBuffers: try makeTileBuffers())
    }

    private func makeTileBuffers() throws -> TileBuffers {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for MetalTile test fixture.")
        }
        let value: UInt32 = 0
        let buffer = device.makeBuffer(bytes: [value], length: MemoryLayout<UInt32>.stride)!
        let ground = TileBuffers.GeometryLayer(verticesBuffer: buffer,
                                               indicesBuffer: buffer,
                                               stylesBuffer: buffer,
                                               overviewStyleMaskBuffer: buffer,
                                               indicesCount: 0,
                                               verticesCount: 0)
        let extruded = TileBuffers.Extruded(verticesBuffer: buffer,
                                            indicesBuffer: buffer,
                                            stylesBuffer: buffer,
                                            indicesCount: 0,
                                            verticesCount: 0)
        let phases = RoadGeometryPhases(shadow: ground,
                                        casing: ground,
                                        fill: ground,
                                        detail: ground,
                                        overlay: ground)
        let roads = RoadStructureBuckets(tunnel: phases,
                                         ground: phases,
                                         bridge: phases)
        let emptyTextLabelSet = TileBuffers.TextLabelSet(placementInputs: [],
                                                         labelsByStyleRuns: [],
                                                         poiIconRuns: [])
        return TileBuffers(ground: ground,
                           roads: roads,
                           bridgeOverlay: ground,
                           extruded: extruded,
                           textLabels: TileBuffers.TextLabels(full: emptyTextLabelSet,
                                                               reduced: emptyTextLabelSet,
                                                               minimal: emptyTextLabelSet),
                           roadLabels: TileBuffers.RoadLabels(pathInputs: [],
                                                              pathRanges: [],
                                                              pathLabels: [],
                                                              labelStyle: nil,
                                                              localGlyphVerticesBuffer: nil,
                                                              localGlyphVertexCount: 0,
                                                              glyphBounds: [],
                                                              glyphBoundRanges: [],
                                                              sizes: [],
                                                              anchorRanges: [],
                                                              anchors: []))
    }
}
