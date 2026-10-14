// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class DebugTileZoomPaletteTests: XCTestCase {
    func testAZoomAlwaysTakesTheSameBrightColour() {
        for zoom in 0 ... 20 {
            let color = DebugTileZoomPalette.color(forZoom: zoom)
            XCTAssertEqual(color, DebugTileZoomPalette.color(forZoom: zoom))
            XCTAssertEqual(color.max(), 1, accuracy: 1e-6, "Full brightness, for the black stroke on a dark map")
            XCTAssertGreaterThanOrEqual(color.min(), 0)
        }
    }

    func testNeighbouringZoomsAreFarApart() {
        for zoom in 0 ... 19 {
            let distance = simd_length(DebugTileZoomPalette.color(forZoom: zoom) - DebugTileZoomPalette.color(forZoom: zoom + 1))
            XCTAssertGreaterThan(distance, 0.5, "z\(zoom) and z\(zoom + 1) must not look alike")
        }
    }

    func testTheHueWheelIsTheUsualOne() {
        XCTAssertEqual(DebugTileZoomPalette.rgb(hue: 0, saturation: 1, value: 1), SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(DebugTileZoomPalette.rgb(hue: 1.0 / 3, saturation: 1, value: 1), SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(DebugTileZoomPalette.rgb(hue: 2.0 / 3, saturation: 1, value: 1), SIMD3<Float>(0, 0, 1))
    }
}
