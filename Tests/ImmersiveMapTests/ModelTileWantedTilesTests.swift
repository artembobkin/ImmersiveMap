// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Which model tiles a frame asks for: the ones over the map tiles it draws
/// and the ring around them, nearest first.
final class ModelTileWantedTilesTests: XCTestCase {
    private typealias Wanted = ModelTileRenderSubsystem.WantedTile

    private func wanted(_ x: Int, _ y: Int, wrap: Int8 = 0) -> Wanted {
        Wanted(tile: Tile(x: x, y: y, z: 14), worldWrap: wrap)
    }

    func testAMapTileOfTheSameZoomWantsItselfAndItsRing() {
        let tiles = ModelTileRenderSubsystem.wantedTiles(visibleTiles: [VisibleTile(x: 9904, y: 5121, z: 14)])

        XCTAssertEqual(tiles.first, wanted(9904, 5121))
        XCTAssertEqual(tiles.count, 9)
        XCTAssertEqual(Set(tiles).count, 9)
        XCTAssertTrue(tiles.contains(wanted(9903, 5120)))
        XCTAssertTrue(tiles.contains(wanted(9905, 5122)))
    }

    /// Four map tiles of zoom 16 inside one model tile ask for it once.
    func testDeeperMapTilesWantTheModelTileOverThem() {
        let visible = [VisibleTile(x: 39616, y: 20484, z: 16),
                       VisibleTile(x: 39617, y: 20484, z: 16),
                       VisibleTile(x: 39616, y: 20485, z: 16),
                       VisibleTile(x: 39619, y: 20487, z: 16)]
        let tiles = ModelTileRenderSubsystem.wantedTiles(visibleTiles: visible)

        XCTAssertEqual(tiles.first, wanted(9904, 5121))
        XCTAssertEqual(tiles.count, 9)
    }

    /// A coarser map tile is far from the camera: its models are not asked for.
    func testCoarserMapTilesWantNothing() {
        XCTAssertTrue(ModelTileRenderSubsystem.wantedTiles(visibleTiles: [VisibleTile(x: 4952, y: 2560, z: 13),
                                                                           VisibleTile(x: 0, y: 0, z: 2)]).isEmpty)
    }

    /// The tiles in view come first, in the coverage's order, and the ring
    /// after them: the store starts loading in this order.
    func testTheTilesInViewComeBeforeTheirRing() {
        let visible = [VisibleTile(x: 9904, y: 5121, z: 14), VisibleTile(x: 9910, y: 5121, z: 14)]
        let tiles = ModelTileRenderSubsystem.wantedTiles(visibleTiles: visible)

        XCTAssertEqual(Array(tiles.prefix(2)), [wanted(9904, 5121), wanted(9910, 5121)])
        XCTAssertEqual(tiles.count, 18)
    }

    /// The world wraps in x and ends in y: a neighbour across the seam is
    /// the far column of the copy of the world next to this one, which is
    /// where it draws.
    func testTheRingCrossesTheSeamIntoTheNextCopyAndStopsAtTheEdge() {
        let tiles = ModelTileRenderSubsystem.wantedTiles(visibleTiles: [VisibleTile(x: 0, y: 0, z: 14)])

        XCTAssertEqual(tiles.count, 6, "no row above the top one")
        XCTAssertTrue(tiles.contains(wanted(16383, 0, wrap: -1)))
        XCTAssertTrue(tiles.contains(wanted(16383, 1, wrap: -1)))
        XCTAssertTrue(tiles.contains(wanted(1, 1)))
        XCTAssertFalse(tiles.contains { $0.tile.y < 0 })
    }

    /// A tile seen in two copies of the world draws in both.
    func testATileKeepsTheCopyOfTheWorldItIsSeenIn() {
        let visible = [VisibleTile(x: 9904, y: 5121, z: 14, worldWrap: 0),
                       VisibleTile(x: 9904, y: 5121, z: 14, worldWrap: 1)]
        let tiles = ModelTileRenderSubsystem.wantedTiles(visibleTiles: visible)

        XCTAssertEqual(Array(tiles.prefix(2)), [wanted(9904, 5121), wanted(9904, 5121, wrap: 1)])
        XCTAssertEqual(tiles.count, 18)
    }

    /// A model tile stands in the flat world where the map's own tile of
    /// the same coordinates does, a tile extent to its edge.
    func testAModelTileIsPlacedWhereTheMapTileIs() {
        let flat = FlatRenderState(pan: SIMD2(0.1, -0.2), renderMapSize: 4096)
        let tile = Tile(x: 9904, y: 5121, z: 14)
        let expected = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x, y: tile.y, z: tile.z,
                                                                   worldWrap: 1,
                                                                   flatRenderPan: flat.pan,
                                                                   renderMapSize: flat.renderMapSize)
        let placement = ModelTileRenderSubsystem.placement(of: tile, worldWrap: 1, flatRenderState: flat)

        XCTAssertEqual(placement.origin, SIMD3(expected.x, expected.y, 0))
        XCTAssertEqual(placement.scale, expected.z / 4096)
        let farCorner = placement.modelMatrix * SIMD4<Float>(4096, 4096, 0, 1)
        XCTAssertEqual(farCorner.x, expected.x + expected.z, accuracy: expected.z * 1e-4)
        XCTAssertEqual(farCorner.y, expected.y + expected.z, accuracy: expected.z * 1e-4)
        let lifted = placement.modelMatrix * SIMD4<Float>(0, 0, 4096, 1)
        XCTAssertEqual(lifted.z, expected.z, accuracy: expected.z * 1e-4, "heights take the same scale")
    }
}
