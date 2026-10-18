// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The flat map's texture bands are placed over a footprint pushed out past
/// the visible ground, so a turn of the camera finds their tiles in.
final class RasterBandMarginTests: XCTestCase {
    func testInflationScalesAboutThePointAndKeepsTheWinding() {
        let polygon = CoveragePolygon(vertices: [SIMD2(1, 1), SIMD2(3, 1), SIMD2(3, 3), SIMD2(1, 3)])
        let inflated = polygon.inflated(about: SIMD2(1, 1), by: 1.5)
        XCTAssertEqual(inflated.vertices, [SIMD2(1, 1), SIMD2(4, 1), SIMD2(4, 4), SIMD2(1, 4)])
        XCTAssertEqual(inflated.signedArea, polygon.signedArea * 2.25, accuracy: 1e-9)
        XCTAssertEqual(polygon.inflated(about: .zero, by: 1).vertices, polygon.vertices, "A factor of one is the polygon")
    }

    func testTheDefaultMarginIsAQuarterAndTheModifierSetsIt() {
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.coverage.rasterBandMarginShare, 0.25)
        XCTAssertEqual(ImmersiveMapSettings.default.tileCoverage(rasterBandMarginShare: 0.5).tiles.coverage.rasterBandMarginShare, 0.5)
        XCTAssertEqual(ImmersiveMapSettings.default.tileCoverage(rasterBandMarginShare: -1).tiles.coverage.rasterBandMarginShare, 0,
                       "Never under none")
    }
}
