// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The atmosphere's public API, as it shipped in 0.7.1: the same fields,
/// the same defaults, the same two modifiers on the settings value and on
/// the view.
final class AtmosphereSettingsTests: XCTestCase {
    func testTheDefaultsAreTheShippedOnes() {
        let atmosphere = ImmersiveMapSettings.AtmosphereSettings()
        XCTAssertTrue(atmosphere.isEnabled)
        XCTAssertEqual(atmosphere.color, SIMD3<Float>(0.40, 0.66, 1.0))
        XCTAssertEqual(atmosphere.intensity, 1.0)
        XCTAssertEqual(atmosphere.thickness, 1.0)
        XCTAssertEqual(atmosphere.sunInfluence, 0.6)
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
