// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

final class TileAtlasPlaceTilesPlannerTests: XCTestCase {
    func testBuildPlacementsKeepsOnlyBaseTargets() throws {
        let baseTile = Tile(x: 1, y: 1, z: 1)
        let baseMetalTile = MetalTile(tile: baseTile, tileBuffers: try makeTileBuffers())

        let context = TileAtlasPlaceTilesPlanner.buildPlacements(
            baseTargets: [VisibleTile(tile: baseTile)],
            readyTilesBySource: [
                baseTile: baseMetalTile
            ],
            baseZoom: 1,
            previousContext: .empty
        )

        XCTAssertEqual(context.tilePlacements.map(\.placeIn.tile), [baseTile])
    }

    func testBuildPlacementsUsesBaseReplacementRules() throws {
        let baseTile = Tile(x: 1, y: 1, z: 1)
        let baseMetalTile = MetalTile(tile: baseTile, tileBuffers: try makeTileBuffers())

        let context = TileAtlasPlaceTilesPlanner.buildPlacements(
            baseTargets: [VisibleTile(tile: baseTile)],
            readyTilesBySource: [
                baseTile: baseMetalTile
            ],
            baseZoom: 1,
            previousContext: .empty
        )

        XCTAssertEqual(context.tilePlacements.count, 1)
        XCTAssertEqual(context.tilePlacements.first?.placeIn.tile, baseTile)
    }

    func testEveryTargetIsUncoveredWhenNothingIsReady() {
        let targets = [Tile(x: 0, y: 0, z: 1), Tile(x: 1, y: 0, z: 1)]

        let context = TileAtlasPlaceTilesPlanner.buildPlacements(
            baseTargets: targets.map { VisibleTile(tile: $0) },
            readyTilesBySource: [:],
            baseZoom: 1,
            previousContext: .empty
        )

        XCTAssertEqual(context.tilePlacements, [])
        XCTAssertEqual(context.uncoveredSlots, targets)
    }

    func testNoSlotIsUncoveredWhenTheExactTileIsPlaced() throws {
        let baseTile = Tile(x: 1, y: 1, z: 1)
        let baseMetalTile = MetalTile(tile: baseTile, tileBuffers: try makeTileBuffers())

        let context = TileAtlasPlaceTilesPlanner.buildPlacements(
            baseTargets: [VisibleTile(tile: baseTile)],
            readyTilesBySource: [baseTile: baseMetalTile],
            baseZoom: 1,
            previousContext: .empty
        )

        XCTAssertEqual(context.uncoveredSlots, [])
    }

    func testNoSlotIsUncoveredWhenAReadyParentFillsTheTarget() throws {
        let parentTile = Tile(x: 0, y: 0, z: 0)
        let parentMetalTile = MetalTile(tile: parentTile, tileBuffers: try makeTileBuffers())
        let target = Tile(x: 1, y: 1, z: 1)

        let context = TileAtlasPlaceTilesPlanner.buildPlacements(
            baseTargets: [VisibleTile(tile: target)],
            readyTilesBySource: [parentTile: parentMetalTile],
            baseZoom: 1,
            previousContext: .empty
        )

        // The parent is placed into the target slot, so its geometry fills the
        // target entirely and the fragment stage has content everywhere in it.
        XCTAssertEqual(context.tilePlacements.map(\.placeIn.tile), [target])
        XCTAssertEqual(context.uncoveredSlots, [])
    }

    func testRetainedPartialCoverageLeavesItsSiblingsUncovered() throws {
        let target = Tile(x: 1, y: 1, z: 1)
        let retainedChild = Tile(x: 2, y: 2, z: 2)
        let retainedMetalTile = MetalTile(tile: retainedChild, tileBuffers: try makeTileBuffers())
        let previousPlacement = TileAtlasPlaceTile(placeTile: PlaceTile(metalTile: retainedMetalTile,
                                                                        placeIn: VisibleTile(tile: retainedChild),
                                                                        lodKind: .exact))

        let context = TileAtlasPlaceTilesPlanner.buildPlacements(
            baseTargets: [VisibleTile(tile: target)],
            readyTilesBySource: [target: nil],
            baseZoom: 1,
            previousContext: TileAtlasPlaceTilesContext(tilePlacements: [previousPlacement],
                                                        uncoveredSlots: [])
        )

        XCTAssertEqual(context.tilePlacements.map(\.placeIn.tile), [retainedChild])
        XCTAssertEqual(Set(context.uncoveredSlots), [Tile(x: 3, y: 2, z: 2),
                                                     Tile(x: 2, y: 3, z: 2),
                                                     Tile(x: 3, y: 3, z: 2)])
    }

    private func makeTileBuffers() throws -> TileBuffers {
        try TileBuffersFixtures.makeEmptyTileBuffers()
    }
}
