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
    /// The northern cap is the style's north cap colour, made opaque: past
    /// the last tile row the planet is the Arctic Ocean.
    func testNorthPoleFollowsTheStyle() {
        let palette = GlobeCapRenderer.makePalette(baseColors: ImmersiveMapBaseColors(
            map: SIMD4<Float>(0.09, 0.10, 0.13, 1),
            northCap: SIMD4<Float>(0.04, 0.09, 0.20, 0.5),
            southCap: SIMD4<Float>(0.30, 0.32, 0.36, 1)))

        assertColor(palette.north.color, equals: SIMD4<Float>(0.04, 0.09, 0.20, 1))
    }

    /// The southern cap is the style's south cap colour: past the last tile
    /// row the planet is the Antarctic ice sheet.
    func testSouthPoleFollowsTheStyle() {
        let palette = GlobeCapRenderer.makePalette(baseColors: ImmersiveMapBaseColors(
            map: SIMD4<Float>(0.09, 0.10, 0.13, 1),
            northCap: SIMD4<Float>(0.04, 0.09, 0.20, 1),
            southCap: SIMD4<Float>(0.30, 0.32, 0.36, 1)))

        assertColor(palette.south.color, equals: SIMD4<Float>(0.30, 0.32, 0.36, 1))
    }

    /// The built-in style's caps are its theme's water and ice: the same
    /// constants the tiles paint the ocean and Antarctica with, so the caps
    /// continue the tiles seamlessly.
    func testTheBuiltInStyleCapsAreTheThemesWaterAndIce() {
        let palette = GlobeCapRenderer.makePalette(baseColors: ProtomapsBasemapDefaultMapStyle().baseColors)

        assertColor(palette.north.color, equals: ProtomapsBasemapTheme.default.layers.water)
        assertColor(palette.south.color, equals: ProtomapsBasemapTheme.default.layers.ice)
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
