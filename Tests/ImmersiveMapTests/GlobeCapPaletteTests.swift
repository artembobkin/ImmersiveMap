// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The polar caps fill the latitudes Mercator tiles never reach, each in one
/// constant colour straight from the style: the north cap continues the open
/// ocean, the south the polar ice sheet. These tests pin where each colour
/// comes from.
final class GlobeCapPaletteTests: XCTestCase {
    /// The northern cap is the palette's water: past the last tile row the
    /// planet is the Arctic Ocean.
    func testNorthPoleFollowsWater() {
        var baseColors = ImmersiveMapSettings.default.style.baseColors
        baseColors.water = SIMD4<Float>(0.04, 0.09, 0.20, 1)
        baseColors.polarIce = SIMD4<Float>(0.30, 0.32, 0.36, 1)

        let palette = GlobeCapRenderer.makePalette(mapBaseColors: ImmersiveMapBaseColors(settings: baseColors))

        assertColor(palette.north.color, equals: SIMD4<Float>(0.04, 0.09, 0.20, 1))
    }

    /// The southern cap is the palette's polar ice: past the last tile row
    /// the planet is the Antarctic ice sheet.
    func testSouthPoleFollowsPolarIce() {
        var baseColors = ImmersiveMapSettings.default.style.baseColors
        baseColors.tileBackground = SIMD4<Float>(0.09, 0.10, 0.13, 1)
        baseColors.polarIce = SIMD4<Float>(0.30, 0.32, 0.36, 1)

        let palette = GlobeCapRenderer.makePalette(mapBaseColors: ImmersiveMapBaseColors(settings: baseColors))

        assertColor(palette.south.color, equals: SIMD4<Float>(0.30, 0.32, 0.36, 1))
    }

    /// A style that says nothing about ice keeps the white south pole the
    /// default daylight palette has always drawn.
    func testDefaultPaletteKeepsWhiteSouthPole() {
        let baseColors = ImmersiveMapSettings.default.style.baseColors

        let palette = GlobeCapRenderer.makePalette(mapBaseColors: ImmersiveMapBaseColors(settings: baseColors))

        assertColor(palette.south.color, equals: SIMD4<Float>(1, 1, 1, 1))
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
