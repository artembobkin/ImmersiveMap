// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The ring rules' grid measure on the sphere: rings of target tiles from
/// the look-at tile, the columns closing at the antimeridian and the rows
/// ending at the poles.
final class GlobeRingMathTests: XCTestCase {
    func testTheLookAtTileIsTheCentreFloored() {
        let tile = GlobeRingMath.lookAtTile(center: Center(tileX: 32.7, tileY: 12.2), targetZoom: 6)
        XCTAssertEqual(tile.x, 32)
        XCTAssertEqual(tile.y, 12)
        let edge = GlobeRingMath.lookAtTile(center: Center(tileX: 64, tileY: -0.5), targetZoom: 6)
        XCTAssertEqual(edge.x, 63, "clamped into the grid")
        XCTAssertEqual(edge.y, 0)
    }

    /// A target tile's ring is the larger of its column and row distances.
    func testATargetTilesRingIsItsGridDistance() {
        let lookAt = (x: 32, y: 32)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 32, y: 32, z: 6), targetZoom: 6, lookAt: lookAt), 0 ... 0)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 33, y: 31, z: 6), targetZoom: 6, lookAt: lookAt), 1 ... 1)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 30, y: 37, z: 6), targetZoom: 6, lookAt: lookAt), 5 ... 5)
    }

    /// A coarser tile spans the rings of its nearest and farthest target
    /// tiles, from 0 when the look-at tile is under it.
    func testACoarserTileSpansItsRings() {
        let lookAt = (x: 32, y: 32)
        // z4/8/8 holds columns and rows 32 to 35.
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 8, y: 8, z: 4), targetZoom: 6, lookAt: lookAt), 0 ... 3)
        // z4/9/8 holds columns 36 to 39.
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 9, y: 8, z: 4), targetZoom: 6, lookAt: lookAt), 4 ... 7)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 0, y: 0, z: 0), targetZoom: 6, lookAt: lookAt), 0 ... 32)
    }

    /// A column's distance is the shorter way around the antimeridian.
    func testTheColumnsCloseOnThemselves() {
        let lookAt = (x: 0, y: 32)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 63, y: 32, z: 6), targetZoom: 6, lookAt: lookAt), 1 ... 1)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 60, y: 32, z: 6), targetZoom: 6, lookAt: lookAt), 4 ... 4)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 32, y: 32, z: 6), targetZoom: 6, lookAt: lookAt), 32 ... 32,
                       "the antipode's column is half the world away")
        // z4/15/8 holds columns 60 to 63, just across the seam.
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 15, y: 8, z: 4), targetZoom: 6, lookAt: lookAt), 1 ... 4)
        // z3/4/4 holds columns 32 to 39: the antipode's column is in it.
        XCTAssertEqual(GlobeRingMath.wrappedAxisRange(first: 32, count: 8, lookAt: 0, tilesCount: 64), 25 ... 32)
        // Columns 24 to 31 lie short of the antipode going up.
        XCTAssertEqual(GlobeRingMath.wrappedAxisRange(first: 24, count: 8, lookAt: 0, tilesCount: 64), 24 ... 31)
    }

    /// The rows do not wrap: past a pole there is no ground.
    func testTheRowsEndAtThePoles() {
        let lookAt = (x: 32, y: 0)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 32, y: 63, z: 6), targetZoom: 6, lookAt: lookAt), 63 ... 63)
        XCTAssertEqual(GlobeRingMath.axisRange(first: 0, count: 4, lookAt: 0), 0 ... 3)
    }

    /// At the shallow zooms the whole world is a few rings wide.
    func testTheShallowWorldIsAFewRingsWide() {
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 0, y: 0, z: 0), targetZoom: 0, lookAt: (0, 0)), 0 ... 0)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 3, y: 2, z: 2), targetZoom: 2, lookAt: (0, 2)), 1 ... 1)
        XCTAssertEqual(GlobeRingMath.ringRange(of: Tile(x: 2, y: 2, z: 2), targetZoom: 2, lookAt: (0, 2)), 2 ... 2)
    }
}
