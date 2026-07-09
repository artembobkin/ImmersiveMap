// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class NightLightsGlobeTextureSubsystemTests: XCTestCase {
    func testRequiredNightLightTilesDeduplicatesMappedTilesAndSortsByZoomYThenX() {
        let tileSet = makeTileSet()
        let visibleTiles = [
            Tile(x: 104, y: 140, z: 8),
            Tile(x: 101, y: 140, z: 8),
            Tile(x: 100, y: 140, z: 8)
        ]

        let requiredTiles = NightLightsGlobeTextureSubsystem.requiredNightLightTiles(for: visibleTiles,
                                                                                     tileSet: tileSet)

        XCTAssertEqual(requiredTiles, [
            Tile(x: 25, y: 35, z: 6),
            Tile(x: 26, y: 35, z: 6)
        ])
    }

    func testRequiredNightLightTilesSortsByZoomThenYThenX() {
        let tileSet = makeTileSet()
        let visibleTiles = [
            Tile(x: 9, y: 2, z: 6),
            Tile(x: 8, y: 2, z: 5),
            Tile(x: 7, y: 1, z: 5),
            Tile(x: 9, y: 9, z: 4),
            Tile(x: 3, y: 2, z: 6),
            Tile(x: 3, y: 2, z: 6)
        ]

        let requiredTiles = NightLightsGlobeTextureSubsystem.requiredNightLightTiles(for: visibleTiles,
                                                                                     tileSet: tileSet)

        XCTAssertEqual(requiredTiles, [
            Tile(x: 9, y: 9, z: 4),
            Tile(x: 7, y: 1, z: 5),
            Tile(x: 8, y: 2, z: 5),
            Tile(x: 3, y: 2, z: 6),
            Tile(x: 9, y: 2, z: 6)
        ])
    }

    func testRequiredNightLightTilesDropsVisibleTilesBelowMinimumZoom() {
        let tileSet = makeTileSet()

        let requiredTiles = NightLightsGlobeTextureSubsystem.requiredNightLightTiles(for: [
            Tile(x: 1, y: 1, z: 2),
            Tile(x: 4, y: 4, z: 4)
        ], tileSet: tileSet)

        XCTAssertEqual(requiredTiles, [
            Tile(x: 4, y: 4, z: 4)
        ])
    }

    func testRenderableRequiredNightLightTilesDeduplicatesInVisibleTileOrder() {
        let tileSet = makeTileSet()

        let requiredTiles = NightLightsGlobeTextureSubsystem.renderableRequiredNightLightTiles(for: [
            Tile(x: 40, y: 44, z: 8),
            Tile(x: 41, y: 44, z: 8),
            Tile(x: 4, y: 4, z: 4),
            Tile(x: 8, y: 2, z: 5)
        ], tileSet: tileSet)

        XCTAssertEqual(requiredTiles, [
            Tile(x: 10, y: 11, z: 6),
            Tile(x: 4, y: 4, z: 4),
            Tile(x: 8, y: 2, z: 5)
        ])
    }

    func testRenderableRequiredNightLightTilesCapsToShaderEntryBudget() {
        let tileSet = makeTileSet()
        let visibleTiles = (0..<(NightLightsAtlasSurfaceBinding.maxEntryCount + 12)).map { index in
            Tile(x: index % 64, y: index / 64, z: 6)
        }

        let requiredTiles = NightLightsGlobeTextureSubsystem.renderableRequiredNightLightTiles(for: visibleTiles,
                                                                                               tileSet: tileSet)

        XCTAssertEqual(requiredTiles.count, NightLightsAtlasSurfaceBinding.maxEntryCount)
        XCTAssertEqual(requiredTiles.first, Tile(x: 0, y: 0, z: 6))
        XCTAssertEqual(requiredTiles.last, Tile(x: 63, y: 1, z: 6))
    }

    func testResolveAvailableTileDataUsesExactTileWhenLoaded() {
        let requiredTile = Tile(x: 10, y: 11, z: 6)
        let loaded: [Tile: NightLightsTileData] = [
            requiredTile: makeTileData(requiredTile)
        ]

        let resolved = NightLightsGlobeTextureSubsystem.resolveAvailableTileData(
            requiredTiles: [requiredTile],
            minZoom: 4
        ) { loaded[$0] }

        XCTAssertEqual(resolved.map(\.tile), [requiredTile])
    }

    func testResolveAvailableTileDataFallsBackToDeepestLoadedAncestor() {
        let requiredTile = Tile(x: 10, y: 11, z: 6)
        // Exact z6 tile not loaded yet; z4 ancestor from a previous zoom still cached.
        let ancestorZoom5 = requiredTile.findParentTile(atZoom: 5)!
        let ancestorZoom4 = requiredTile.findParentTile(atZoom: 4)!
        let loaded: [Tile: NightLightsTileData] = [
            ancestorZoom4: makeTileData(ancestorZoom4)
        ]

        let resolved = NightLightsGlobeTextureSubsystem.resolveAvailableTileData(
            requiredTiles: [requiredTile],
            minZoom: 4
        ) { loaded[$0] }

        XCTAssertEqual(resolved.map(\.tile), [ancestorZoom4])
        XCTAssertNil(loaded[ancestorZoom5])
    }

    func testResolveAvailableTileDataPrefersShallowerZoomTowardDeepestAvailableAncestor() {
        let requiredTile = Tile(x: 10, y: 11, z: 6)
        let ancestorZoom5 = requiredTile.findParentTile(atZoom: 5)!
        let ancestorZoom4 = requiredTile.findParentTile(atZoom: 4)!
        // Both ancestors cached: the deepest (closest) one must win.
        let loaded: [Tile: NightLightsTileData] = [
            ancestorZoom5: makeTileData(ancestorZoom5),
            ancestorZoom4: makeTileData(ancestorZoom4)
        ]

        let resolved = NightLightsGlobeTextureSubsystem.resolveAvailableTileData(
            requiredTiles: [requiredTile],
            minZoom: 4
        ) { loaded[$0] }

        XCTAssertEqual(resolved.map(\.tile), [ancestorZoom5])
    }

    func testResolveAvailableTileDataDeduplicatesSharedAncestorFallback() {
        let siblingA = Tile(x: 20, y: 22, z: 6)
        let siblingB = Tile(x: 21, y: 22, z: 6)
        let sharedAncestor = siblingA.findParentTile(atZoom: 4)!
        XCTAssertEqual(siblingB.findParentTile(atZoom: 4), sharedAncestor)
        let loaded: [Tile: NightLightsTileData] = [
            sharedAncestor: makeTileData(sharedAncestor)
        ]

        let resolved = NightLightsGlobeTextureSubsystem.resolveAvailableTileData(
            requiredTiles: [siblingA, siblingB],
            minZoom: 4
        ) { loaded[$0] }

        XCTAssertEqual(resolved.map(\.tile), [sharedAncestor])
    }

    func testResolveAvailableTileDataSkipsTileWithNoLoadedAncestor() {
        let requiredTile = Tile(x: 10, y: 11, z: 6)

        let resolved = NightLightsGlobeTextureSubsystem.resolveAvailableTileData(
            requiredTiles: [requiredTile],
            minZoom: 4
        ) { _ in nil }

        XCTAssertTrue(resolved.isEmpty)
    }

    private func makeTileData(_ tile: Tile) -> NightLightsTileData {
        NightLightsTileData(tile: tile, width: 1, height: 1, bytes: [0, 0])
    }

    private func makeTileSet() -> NightLightsTileSet {
        NightLightsTileSet(metadata: NightLightsTileSet.Metadata(version: 1,
                                                                 format: "jpg",
                                                                 tileSize: 1024,
                                                                 minZoom: 4,
                                                                 maxZoom: 6,
                                                                 source: "NASA Black Marble 2016",
                                                                 attribution: "NASA Earth Observatory"))
    }
}
