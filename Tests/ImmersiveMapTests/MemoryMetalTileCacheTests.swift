// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

/// World-coverage pinning: tiles with z <= 3, once in the cache, survive
/// regular LRU pressure but are released on memory warning (if not visible)
/// and on a full clear.
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
                        "A pinned z3 tile must not be evicted by ordinary pressure")
        XCTAssertNil(cache.getTile(forKey: highZoomTiles[0]),
                     "Old ordinary tiles must be evicted under a one-byte limit")
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

    // A 1-byte limit: any insertion creates eviction pressure, which lets us
    // test pinned-tile protection without knowing actual buffer sizes.
    private func makeCache() -> MemoryMetalTileCache {
        MemoryMetalTileCache(maxCacheSizeInBytes: 1,
                             tileTraceRecorder: TileTraceRecorder())
    }

    private func makeMetalTile(_ tile: Tile) throws -> MetalTile {
        MetalTile(tile: tile, tileBuffers: try makeTileBuffers())
    }

    private func makeTileBuffers() throws -> TileBuffers {
        try TileBuffersFixtures.makeEmptyTileBuffers()
    }
}
