// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapSettingsDefaultsTests: XCTestCase {
    func testDefaultLabelLanguageIsEnglish() {
        XCTAssertEqual(ImmersiveMapSettings.default.labels.language, .english)
    }

    func testDefaultSceneLightMatchesLegacyHardcodedDirection() {
        XCTAssertEqual(ImmersiveMapSettings.default.scene.light.direction, SIMD3<Float>(-0.4, -0.6, 1.0))
    }

    func testDefaultShadowsAreEnabled() {
        let shadows = ImmersiveMapSettings.default.scene.shadows
        XCTAssertTrue(shadows.isEnabled)
        XCTAssertEqual(shadows.strength, 0.22)
        XCTAssertEqual(shadows.mapResolution, 2048)
        XCTAssertEqual(shadows.coverageCameraDistances, 3.0)
    }

    /// The default shadow is soft and cool: light enough that a shadowed street
    /// still reads as daylight, tinted toward the sky rather than toward grey.
    func testDefaultShadowTintIsCool() {
        let tint = ImmersiveMapSettings.default.scene.shadows.tint
        XCTAssertLessThan(tint.x, tint.y)
        XCTAssertLessThan(tint.y, tint.z)
        XCTAssertEqual(tint.z, 1.0)
    }


    /// The map color, the tile background and the built-in style's land are one
    /// color: a tile that has not arrived, the placeholder globe and the horizon
    /// haze all wear the ground the tiles paint, so loading never flashes a
    /// lighter patch. The base water follows the style's water for the same
    /// reason: the polar cap continues the ocean with it.
    func testMapColorAndBaseColorsMatchTheBuiltInPalette() {
        let settings = ImmersiveMapSettings.default
        let layers = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.layers
        let mapColor = settings.scene.mapClearColor
        XCTAssertEqual(SIMD4<Float>(Float(mapColor.x), Float(mapColor.y), Float(mapColor.z), Float(mapColor.w)),
                       layers.land)
        XCTAssertEqual(settings.style.baseColors.tileBackground, layers.land)
        XCTAssertEqual(settings.style.baseColors.water, layers.water)
    }

    /// The overview biomes and the street palette are one set of colors, class
    /// by class, so nothing shifts hue while zooming.
    func testOverviewBiomesMirrorTheStreetPalette() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let biomes = configuration.globalLandcover
        let layers = configuration.layers
        XCTAssertEqual(biomes.land, layers.land)
        XCTAssertEqual(biomes.water, layers.water)
        XCTAssertEqual(biomes.forest, layers.wood)
        XCTAssertEqual(biomes.grass, layers.grass)
        XCTAssertEqual(biomes.crop, layers.farmland)
        XCTAssertEqual(biomes.barren, layers.sand)
        XCTAssertEqual(biomes.wetland, layers.wetland)
        XCTAssertEqual(biomes.snow, layers.ice)
    }
}
