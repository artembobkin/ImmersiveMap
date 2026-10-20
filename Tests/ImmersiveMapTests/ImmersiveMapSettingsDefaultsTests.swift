// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapSettingsDefaultsTests: XCTestCase {
    func testDefaultLabelLanguageIsEnglish() {
        XCTAssertEqual(ImmersiveMapSettings.default.labels.language, .english)
    }

    func testDefaultLabelsAreEnabled() {
        XCTAssertTrue(ImmersiveMapSettings.default.labels.isEnabled)
        XCTAssertFalse(ImmersiveMapSettings.default.labels(isEnabled: false).labels.isEnabled)
    }

    func testDefaultSceneLightMatchesLegacyHardcodedDirection() {
        XCTAssertEqual(ImmersiveMapSettings.default.scene.light.direction, SIMD3<Float>(-0.4, -0.6, 1.0))
    }

    /// The air over the mountains is on by default: the mountain air made
    /// of the default plain air, so a pan into a range fades into it
    /// without an app setting it.
    func testDefaultMountainAirIsOn() {
        let scene = ImmersiveMapSettings.default.scene
        XCTAssertEqual(scene.mountainGroundFog, ImmersiveMapSettings.GroundFogSettings.mountainAir(from: scene.groundFog))
        XCTAssertEqual(scene.mountainGroundFog?.isEnabled, true)
        XCTAssertEqual(scene.mountainGroundFog?.baseAltitudeMeters, 1500)
        XCTAssertNil(ImmersiveMapSettings.default.mountainGroundFog(nil).scene.mountainGroundFog, "One air everywhere on request")
    }

    func testDefaultShadowsAreEnabled() {
        let shadows = ImmersiveMapSettings.default.scene.shadows
        XCTAssertTrue(shadows.isEnabled)
        XCTAssertEqual(shadows.strength, [14: 0, 15: 0.22])
        XCTAssertEqual(shadows.mapResolution, 4096)
        XCTAssertEqual(shadows.nearCoverageMeters, [12: 24_000, 14: 6000, 16: 1500, 18: 500])
        XCTAssertEqual(shadows.farCoverageMeters, [12: 96_000, 14: 24_000, 16: 6000, 18: 1500])
        XCTAssertEqual(shadows.normalOffsetTexels, 2.5)
        XCTAssertEqual(shadows.maxCasterHeightMeters, 500)
        XCTAssertEqual(shadows.softness, 1.5)
    }

    /// The default shadow is soft and cool: light enough that a shadowed street
    /// still reads as daylight, tinted toward the sky rather than toward grey.
    func testDefaultShadowTintIsCool() {
        let tint = ImmersiveMapSettings.default.scene.shadows.tint
        XCTAssertLessThan(tint.x, tint.y)
        XCTAssertLessThan(tint.y, tint.z)
        XCTAssertEqual(tint.z, 1.0)
    }


    /// What no tile paints comes from the same palette as the tiles: a tile
    /// that has not arrived, the horizon haze and the placeholder globe wear
    /// the land, the north cap the water and the south cap the ice, so
    /// loading never flashes a lighter patch and a cap never punches a hole.
    func testTheBaseColoursAreTheThemesLandWaterAndIce() {
        let theme = ProtomapsBasemapTheme.default
        let base = ProtomapsBasemapDefaultMapStyle(theme: theme).baseColors
        XCTAssertEqual(base.map, theme.layers.land)
        XCTAssertEqual(base.northCap, theme.layers.water)
        XCTAssertEqual(base.southCap, theme.layers.ice)
    }
}
