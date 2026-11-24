// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Which tiles the tile grid draws: those the view lets through, the
/// nearest to where the camera looks first, no more than the limit.
final class TileGridCoverageTests: XCTestCase {
    private let root = [VisibleTile(x: 0, y: 0, z: 0)]

    func testEveryTileOfTheZoomIsReachedWhenAllShow() {
        let tiles = TileGridCoverage.nearest(zoom: 3, limit: 1000, roots: root, centre: SIMD2(0.5, 0.5),
                                             wrapsRound: false) { _ in .descend }
        XCTAssertEqual(tiles.count, 64)
        XCTAssertEqual(Set(tiles).count, 64)
        XCTAssertTrue(tiles.allSatisfy { $0.z == 3 })
    }

    func testTheLimitKeepsTheNearest() {
        let centre = SIMD2<Double>(0.30, 0.70)
        let tiles = TileGridCoverage.nearest(zoom: 6, limit: 9, roots: root, centre: centre,
                                             wrapsRound: false) { _ in .descend }
        XCTAssertEqual(tiles.count, 9)
        XCTAssertEqual(tiles.first?.tile, Tile.containing(normalizedWorld: centre, zoom: 6), "The tile under the camera first")
        let distances = tiles.map { TileGridCoverage.distanceSquared(from: centre, to: $0, wrapsRound: false) }
        XCTAssertEqual(distances, distances.sorted())
        // The block of three by three round the centre tile.
        let home = Tile.containing(normalizedWorld: centre, zoom: 6)
        XCTAssertTrue(tiles.allSatisfy { abs($0.x - home.x) <= 1 && abs($0.y - home.y) <= 1 })
    }

    func testARejectedTileIsNotLookedInto() {
        var asked: [VisibleTile] = []
        let tiles = TileGridCoverage.nearest(zoom: 4, limit: 1000, roots: root, centre: SIMD2(0.1, 0.1),
                                             wrapsRound: false) { node in
            asked.append(node)
            // The world's western half alone shows.
            return node.z > 0 && node.x >= 1 << (node.z - 1) ? .reject : .descend
        }
        XCTAssertEqual(tiles.count, 8 * 16)
        XCTAssertTrue(tiles.allSatisfy { $0.x < 8 })
        XCTAssertFalse(asked.contains { $0.z == 2 && $0.x >= 2 }, "Nothing under a rejected tile is asked")
    }

    func testAnAcceptedSubtreeIsNotAskedAgain() {
        var askedBelowRoot = 0
        let tiles = TileGridCoverage.nearest(zoom: 3, limit: 1000, roots: root, centre: SIMD2(0.5, 0.5),
                                             wrapsRound: false) { node in
            if node.z > 0 { askedBelowRoot += 1 }
            return .acceptSubtree
        }
        XCTAssertEqual(tiles.count, 64)
        XCTAssertEqual(askedBelowRoot, 0)
    }

    func testNothingIsDrawnWithoutALimit() {
        XCTAssertTrue(TileGridCoverage.nearest(zoom: 3, limit: 0, roots: root, centre: SIMD2(0.5, 0.5),
                                               wrapsRound: false) { _ in .descend }.isEmpty)
    }

    func testTheSphereClosesRoundTheAntimeridian() {
        let east = VisibleTile(x: 7, y: 3, z: 3)
        let centre = SIMD2<Double>(0.01, 0.4)
        XCTAssertEqual(TileGridCoverage.distanceSquared(from: centre, to: east, wrapsRound: true), 0.01 * 0.01,
                       accuracy: 1e-12, "The tile across the antimeridian is a step away")
        XCTAssertGreaterThan(TileGridCoverage.distanceSquared(from: centre, to: east, wrapsRound: false), 0.7)
    }

    func testTheFlatMapShowsTheTilesUnderItsFootprintInEveryCopy() {
        // A world one unit wide, seen as a small square round its middle.
        let state = FlatRenderState(pan: .zero, renderMapSize: 1)
        let polygon = CoveragePolygon(vertices: [SIMD2(-0.1, -0.1), SIMD2(-0.1, 0.1), SIMD2(0.1, 0.1), SIMD2(0.1, -0.1)])
        let tiles = TileGridCoverage.flat(zoom: 2, limit: 100, polygon: polygon, flatRenderState: state,
                                          centre: SIMD2(0.5, 0.5))
        XCTAssertEqual(Set(tiles), [VisibleTile(x: 1, y: 1, z: 2), VisibleTile(x: 2, y: 1, z: 2),
                                    VisibleTile(x: 1, y: 2, z: 2), VisibleTile(x: 2, y: 2, z: 2)])

        // The same square over the antimeridian: both copies of the world.
        let seam = CoveragePolygon(vertices: [SIMD2(0.4, -0.1), SIMD2(0.4, 0.1), SIMD2(0.6, 0.1), SIMD2(0.6, -0.1)])
        let seamTiles = TileGridCoverage.flat(zoom: 2, limit: 100, polygon: seam, flatRenderState: state,
                                              centre: SIMD2(1.0, 0.5))
        XCTAssertTrue(seamTiles.contains(VisibleTile(x: 3, y: 1, z: 2, worldWrap: 0)))
        XCTAssertTrue(seamTiles.contains(VisibleTile(x: 0, y: 1, z: 2, worldWrap: 1)))
        XCTAssertEqual(TileGridCoverage.flatCopies(showing: Tile(x: 0, y: 1, z: 2), polygon: seam, flatRenderState: state),
                       [VisibleTile(x: 0, y: 1, z: 2, worldWrap: 1)])
        XCTAssertTrue(TileGridCoverage.flatCopies(showing: Tile(x: 1, y: 0, z: 2), polygon: seam,
                                                  flatRenderState: state).isEmpty)
    }
}
