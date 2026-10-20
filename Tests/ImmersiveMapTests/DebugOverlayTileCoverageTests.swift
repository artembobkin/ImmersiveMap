// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The debug panel's coverage map (`DebugOverlayTileCoverage`): the
/// frame's placements from above, in normalized Mercator.
final class DebugOverlayTileCoverageTests: XCTestCase {
    private typealias Placement = DebugOverlayTileCoverage.Placement

    func testASlotIsItsSquareOfMercator() {
        let placement = Placement(slot: Tile(x: 1, y: 2, z: 2), source: Tile(x: 0, y: 1, z: 1), worldWrap: 0)
        XCTAssertEqual(placement.square, CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25))
        XCTAssertTrue(placement.isStandIn)
        let wrapped = Placement(slot: Tile(x: 0, y: 0, z: 1), source: Tile(x: 0, y: 0, z: 1), worldWrap: 1)
        XCTAssertEqual(wrapped.square, CGRect(x: 1, y: 0, width: 0.5, height: 0.5), "A copy of the world one unit east")
        XCTAssertFalse(wrapped.isStandIn)
    }

    func testTheFlatWorldMapsBackOntoMercator() {
        // The inverse of the tile origin: zoom 0's tile covers the world.
        let flat = FlatRenderState(pan: SIMD2<Double>(0.2, -0.4), renderMapSize: 10)
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: 0, y: 0, z: 0, worldWrap: 0,
                                                                  flatRenderPan: flat.pan, renderMapSize: flat.renderMapSize)
        let southWest = DebugOverlayTileCoverage.mercator(flatWorld: SIMD2<Double>(Double(origin.x), Double(origin.y)), flatRenderState: flat)
        XCTAssertEqual(southWest.x, 0, accuracy: 1e-9)
        XCTAssertEqual(southWest.y, 1, accuracy: 1e-9, "The flat world is y up, Mercator y south")
        let northEast = DebugOverlayTileCoverage.mercator(flatWorld: SIMD2<Double>(Double(origin.x + origin.z), Double(origin.y + origin.z)),
                                                          flatRenderState: flat)
        XCTAssertEqual(northEast.x, 1, accuracy: 1e-9)
        XCTAssertEqual(northEast.y, 0, accuracy: 1e-9)
        // A zoom 3 tile lands on its own square.
        let tile = ImmersiveMapProjection.flatTileOriginAndSize(x: 5, y: 2, z: 3, worldWrap: 0,
                                                                flatRenderPan: flat.pan, renderMapSize: flat.renderMapSize)
        let corner = DebugOverlayTileCoverage.mercator(flatWorld: SIMD2<Double>(Double(tile.x), Double(tile.y + tile.z)), flatRenderState: flat)
        XCTAssertEqual(corner.x, 5.0 / 8, accuracy: 1e-6)
        XCTAssertEqual(corner.y, 2.0 / 8, accuracy: 1e-6, "The tile's north-west corner")
    }

    func testTheWindowIsSquareRoundTheSlotsAndNotTheFootprint() {
        let coverage = DebugOverlayTileCoverage(
            placements: [Placement(slot: Tile(x: 2, y: 1, z: 2), source: Tile(x: 2, y: 1, z: 2), worldWrap: 0),
                         Placement(slot: Tile(x: 3, y: 1, z: 2), source: Tile(x: 3, y: 1, z: 2), worldWrap: 0)],
            // A camera on the horizon: the footprint reaches far past the
            // tiles, and must not shrink them into a corner.
            footprint: [SIMD2<Double>(0.5, 0.25), SIMD2<Double>(9.0, 0.25), SIMD2<Double>(0.75, 9.0)],
            center: SIMD2<Double>(0.6, 0.3),
            eye: nil)
        let window = DebugOverlayTileCoverageLayout.window(for: coverage)
        XCTAssertEqual(window.width, window.height, "Square, so the north stays up and nothing is stretched")
        XCTAssertEqual(window.midX, 0.75, accuracy: 1e-9)
        XCTAssertEqual(window.midY, 0.375, accuracy: 1e-9)
        XCTAssertEqual(window.width, 0.5 * 1.12, accuracy: 1e-9, "The slots' bounds plus the margin")

        let point = DebugOverlayTileCoverageLayout.point(SIMD2<Double>(window.minX, window.minY), window: window, side: 280)
        XCTAssertEqual(point, CGPoint(x: 0, y: 0))
        let rect = DebugOverlayTileCoverageLayout.rect(coverage.placements[0].square, window: window, side: 280)
        XCTAssertEqual(rect.width, 280 * 0.25 / window.width, accuracy: 1e-6)
    }

    func testAnEmptyFrameShowsTheWorldRoundTheCentre() {
        let coverage = DebugOverlayTileCoverage(placements: [], footprint: [], center: SIMD2<Double>(0.5, 0.5), eye: nil)
        XCTAssertEqual(DebugOverlayTileCoverageLayout.window(for: coverage), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The horizon backdrop, the world tile under everything, is left off
    /// the map: its square is the whole world, and a window round it
    /// shrank the frame's tiles to a few pixels.
    func testTheHorizonBackdropIsLeftOffTheMap() throws {
        func placeTile(_ tile: Tile, isHorizonBackdrop: Bool = false) throws -> PlaceTile {
            PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers()),
                      placeIn: VisibleTile(tile: tile),
                      isHorizonBackdrop: isHorizonBackdrop)
        }
        let placements = DebugOverlayTileCoverage.placements(of: [
            try placeTile(TileWorkingSetSubsystem.horizonBackdropTile, isHorizonBackdrop: true),
            try placeTile(Tile(x: 2134, y: 1456, z: 12)),
        ])
        XCTAssertEqual(placements.map(\.slot), [Tile(x: 2134, y: 1456, z: 12)])
        let coverage = DebugOverlayTileCoverage(placements: placements, footprint: [], center: SIMD2<Double>(0.52, 0.36), eye: nil)
        XCTAssertLessThan(DebugOverlayTileCoverageLayout.window(for: coverage).width, 0.01, "A window round the frame's tile, not the world")
    }

    func testTheCoarseSlotsDrawFirst() {
        let fine = Placement(slot: Tile(x: 4, y: 4, z: 3), source: Tile(x: 4, y: 4, z: 3), worldWrap: 0)
        let coarse = Placement(slot: Tile(x: 1, y: 1, z: 1), source: Tile(x: 1, y: 1, z: 1), worldWrap: 0)
        XCTAssertEqual(DebugOverlayTileCoverageLayout.drawingOrder([fine, coarse]), [coarse, fine])
    }
}
