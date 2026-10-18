// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The atmosphere's public API: its fields and defaults, the thickness a
/// curve over the zoom, and the two modifiers on the settings value and
/// on the view.
@MainActor
final class AtmosphereSettingsTests: XCTestCase {
    func testTheDefaultsAreTheShippedOnes() {
        let atmosphere = ImmersiveMapSettings.AtmosphereSettings()
        XCTAssertTrue(atmosphere.isEnabled)
        XCTAssertEqual(atmosphere.color, SIMD3<Float>(0.008, 0.18, 0.482))
        XCTAssertEqual(atmosphere.intensity, 1.2)
        XCTAssertEqual(atmosphere.thickness, [2: 3, 6: 0.25])
        XCTAssertEqual(atmosphere.thickness.value(atZoom: 0), 3, "A wide glow around the whole planet")
        XCTAssertEqual(atmosphere.thickness.value(atZoom: 7), 0.25, "A thin ring by the unroll")
        XCTAssertEqual(atmosphere.sunInfluence, 0.69)
        XCTAssertEqual(ImmersiveMapSettings.default.scene.atmosphere, atmosphere)
    }

    func testTheModifiersWriteThrough() {
        let custom = ImmersiveMapSettings.AtmosphereSettings(isEnabled: true,
                                                             color: SIMD3<Float>(1, 0.5, 0.2),
                                                             intensity: 0.4,
                                                             thickness: 1.5,
                                                             sunInfluence: 0)
        XCTAssertEqual(ImmersiveMapSettings.default.atmosphereSettings(custom).scene.atmosphere, custom)
        XCTAssertFalse(ImmersiveMapSettings.default.atmosphere(isEnabled: false).scene.atmosphere.isEnabled)
        XCTAssertTrue(ImmersiveMapSettings.default.atmosphere(isEnabled: false).atmosphere().scene.atmosphere.isEnabled)

        let view = ImmersiveMapView().atmosphereSettings(custom)
        XCTAssertEqual(view.settings.scene.atmosphere, custom)
        XCTAssertFalse(ImmersiveMapView().atmosphere(isEnabled: false).settings.scene.atmosphere.isEnabled)
    }
}
