// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Pins the Swift mirror of `GlobeSurfaceTile` in TileSphere.metal.
final class GlobeVectorSurfaceUniformLayoutTests: XCTestCase {
    func testSurfaceTileUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.stride, 32)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.tile), 0)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceTileUniform>.offset(of: \.lift), 16)
        let uniform = GlobeSurfaceTileUniform(tile: Tile(x: 3, y: 5, z: 4), lift: 0.25)
        XCTAssertEqual(uniform.tile, SIMD3<Int32>(3, 5, 4))
        XCTAssertEqual(uniform.lift, 0.25)
    }
}

/// The lift must clear both chord sags at every zoom and never fall below
/// the depth-resolution floor.
final class GlobeSurfaceLiftTests: XCTestCase {
    func testLiftClearsBothSagsWithMarginAndNeverFallsBelowTheFloor() {
        var previous = Float.greatestFiniteMagnitude
        for zoom in 0...12 {
            let lift = GlobeSurfaceLift.factor(sourceTileZoom: zoom)
            XCTAssertGreaterThanOrEqual(lift, GlobeSurfaceLift.minimum)
            XCTAssertGreaterThan(lift, GlobeSurfaceLift.polygonSag(tileZoom: zoom))
            XCTAssertGreaterThan(lift, GlobeSurfaceLift.gridSag(tileZoom: zoom))
            XCTAssertLessThanOrEqual(lift, previous, "The lift shrinks as the tiles get finer")
            previous = lift
        }
    }

    func testSagsComputedIndependently() {
        // z0, step 64 of 4096 over a full equator: theta = 2 pi 64 / 4096.
        let theta = 2 * Float.pi * 64 / 4096
        XCTAssertEqual(GlobeSurfaceLift.polygonSag(tileZoom: 0), 1 - cos(theta / 2), accuracy: 1e-7)
        // z0's tile spans the whole Mercator latitude range over 60 rows.
        let maxLatitude = 2 * atan(exp(Float.pi)) - Float.pi / 2
        XCTAssertEqual(GlobeSurfaceLift.gridSag(tileZoom: 0), 1 - cos(2 * maxLatitude / 60 / 2), accuracy: 1e-7)
        XCTAssertEqual(GlobeSurfaceLift.polygonSag(tileZoom: 10), 0, "No split, no polygon sag")
        XCTAssertEqual(GlobeSurfaceLift.factor(sourceTileZoom: 12), GlobeSurfaceLift.minimum)
    }
}

final class GlobeLineDashScaleTests: XCTestCase {
    func testCoarseTilesKeepTheZ1DashProportion() {
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 0), 0.7)
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 1), 0.7)
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 2), 0.9)
        XCTAssertEqual(GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: 3), 1.0)
    }
}
