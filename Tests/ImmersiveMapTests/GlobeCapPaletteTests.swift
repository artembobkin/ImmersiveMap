// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The polar caps fill the latitudes Mercator tiles never reach, and each one
/// fades from the last row of tiles at its rim into a single color at the pole.
/// These tests pin where that color comes from, because getting it from the
/// wrong place is invisible in a light palette and a bright spot in a dark one.
final class GlobeCapPaletteTests: XCTestCase {
    private let maxLatitude = Float(WebMercatorMath.maxLatitudeRadians)

    func testNorthPoleFollowsPaletteWater() {
        var baseColors = ImmersiveMapSettings.default.style.baseColors
        baseColors.water = SIMD4<Float>(0.04, 0.09, 0.20, 1)

        let palette = GlobeCapRenderer.makePalette(mapBaseColors: ImmersiveMapBaseColors(settings: baseColors),
                                                   maxLatitude: maxLatitude)

        assertColor(palette.north.fillColor, equals: SIMD4<Float>(0.04, 0.09, 0.20, 1))
    }

    func testSouthPoleFollowsPolarIceRatherThanTileBackground() {
        var baseColors = ImmersiveMapSettings.default.style.baseColors
        baseColors.tileBackground = SIMD4<Float>(0.09, 0.10, 0.13, 1)
        baseColors.polarIce = SIMD4<Float>(0.30, 0.32, 0.36, 1)

        let palette = GlobeCapRenderer.makePalette(mapBaseColors: ImmersiveMapBaseColors(settings: baseColors),
                                                   maxLatitude: maxLatitude)

        assertColor(palette.south.fillColor, equals: SIMD4<Float>(0.30, 0.32, 0.36, 1))
    }

    /// A style that says nothing about ice keeps the white pole the default
    /// daylight palette has always drawn.
    func testDefaultPaletteKeepsWhiteSouthPole() {
        let baseColors = ImmersiveMapSettings.default.style.baseColors

        let palette = GlobeCapRenderer.makePalette(mapBaseColors: ImmersiveMapBaseColors(settings: baseColors),
                                                   maxLatitude: maxLatitude)

        assertColor(palette.south.fillColor, equals: SIMD4<Float>(1, 1, 1, 1))
    }

    private func assertColor(_ color: SIMD4<Float>,
                             equals expected: SIMD4<Float>,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(color.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color.y, expected.y, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color.z, expected.z, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color.w, expected.w, accuracy: 0.0001, file: file, line: line)
    }
}
