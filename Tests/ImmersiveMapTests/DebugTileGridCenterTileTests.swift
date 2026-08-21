// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class DebugTileGridCenterTileTests: XCTestCase {
    func testNoPlaceTilesYieldsNoCandidate() throws {
        XCTAssertTrue(DebugTileGridCenterTile.candidates(placeTiles: [],
                                                          centerWorldMercator: SIMD2<Double>(0.5, 0.5)).isEmpty)
    }

    func testExactlyOneTileOfACoverContainsTheCentre() throws {
        // Zoom two, so the world is a four by four grid; the centre sits inside
        // tile (2, 1) at world (0.6, 0.4).
        let placeTiles = try makePlaceTiles(coordinates: (0..<4).flatMap { row in
            (0..<4).map { column in (x: column, y: row, loop: Int8(0)) }
        }, zoom: 2)

        let candidates = DebugTileGridCenterTile.candidates(placeTiles: placeTiles,
                                                            centerWorldMercator: SIMD2<Double>(0.6, 0.4))

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.placeIn.tile, Tile(x: 2, y: 1, z: 2))
    }

    /// A centre landing exactly on a shared edge belongs to the tile the edge starts,
    /// never to both, or the grid would flicker between two tiles while panning.
    func testCentreOnATileEdgeBelongsToOneTileOnly() throws {
        let placeTiles = try makePlaceTiles(coordinates: [(x: 0, y: 0, loop: 0),
                                                          (x: 1, y: 0, loop: 0),
                                                          (x: 0, y: 1, loop: 0),
                                                          (x: 1, y: 1, loop: 0)],
                                            zoom: 1)

        let candidates = DebugTileGridCenterTile.candidates(placeTiles: placeTiles,
                                                            centerWorldMercator: SIMD2<Double>(0.5, 0.5))

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.placeIn.tile, Tile(x: 1, y: 1, z: 1))
    }

    func testWrappedWorldCopiesAllContainTheCentre() throws {
        let placeTiles = try makePlaceTiles(coordinates: [(x: 1, y: 0, loop: -1),
                                                          (x: 1, y: 0, loop: 0),
                                                          (x: 1, y: 0, loop: 1),
                                                          (x: 0, y: 0, loop: 0)],
                                            zoom: 1)

        let candidates = DebugTileGridCenterTile.candidates(placeTiles: placeTiles,
                                                            centerWorldMercator: SIMD2<Double>(0.75, 0.25))

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(Set(candidates.map(\.placeIn.loop)), [-1, 0, 1])
    }

    func testNearestToViewportCenterPicksTheCopyUnderTheMiddleOfTheView() throws {
        let candidates = try makePlaceTiles(coordinates: [(x: 1, y: 0, loop: -1),
                                                          (x: 1, y: 0, loop: 0),
                                                          (x: 1, y: 0, loop: 1)],
                                            zoom: 1)
        let viewportSize = SIMD2<Float>(1000, 800)
        let projected = [
            ScreenPointOutput(position: SIMD2<Float>(-900, 400), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(520, 380), depth: 0, visible: 1),
            ScreenPointOutput(position: SIMD2<Float>(1900, 400), depth: 0, visible: 1)
        ]

        let picked = DebugTileGridCenterTile.nearestToViewportCenter(candidates: candidates,
                                                                      projectedCenters: projected,
                                                                      viewportSize: viewportSize)

        XCTAssertEqual(picked?.placeIn.loop, 0)
    }

    func testNearestToViewportCenterIgnoresCopiesThatDoNotProject() throws {
        let candidates = try makePlaceTiles(coordinates: [(x: 1, y: 0, loop: 0),
                                                          (x: 1, y: 0, loop: 1)],
                                            zoom: 1)
        let projected = [
            // Closest to the middle, but behind the camera, so it is not on screen.
            ScreenPointOutput(position: SIMD2<Float>(500, 400), depth: 0, visible: 0),
            ScreenPointOutput(position: SIMD2<Float>(900, 400), depth: 0, visible: 1)
        ]

        let picked = DebugTileGridCenterTile.nearestToViewportCenter(candidates: candidates,
                                                                      projectedCenters: projected,
                                                                      viewportSize: SIMD2<Float>(1000, 800))

        XCTAssertEqual(picked?.placeIn.loop, 1)
    }

    private func makePlaceTiles(coordinates: [(x: Int, y: Int, loop: Int8)],
                                zoom: Int) throws -> [PlaceTile] {
        try coordinates.map { coordinate in
            let tile = Tile(x: coordinate.x, y: coordinate.y, z: zoom)
            return PlaceTile(metalTile: MetalTile(tile: tile,
                                                  tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers()),
                             placeIn: VisibleTile(tile: tile, loop: coordinate.loop),
                             lodKind: .exact)
        }
    }
}
