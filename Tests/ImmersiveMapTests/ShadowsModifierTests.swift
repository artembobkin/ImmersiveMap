// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The `shadows` modifier sets the values it is given in place and leaves
/// every other one as configured.
final class ShadowsModifierTests: XCTestCase {
    @MainActor
    func testAValueSetInPlaceLeavesTheOthers() {
        let settings = ImmersiveMapView()
            .shadows(strength: 0.4, nearCoverageMeters: [14: 5000, 18: 400])
            .shadows(farCoverageMeters: 20_000, maxCasterHeightMeters: 120)
            .settings
        let shadows = settings.scene.shadows
        let defaults = ImmersiveMapSettings.default.scene.shadows

        XCTAssertTrue(shadows.isEnabled)
        XCTAssertEqual(shadows.maxCasterHeightMeters, 120)
        XCTAssertEqual(shadows.strength, 0.4, "Set by the first modifier, kept by the second")
        XCTAssertEqual(shadows.nearCoverageMeters, [14: 5000, 18: 400])
        XCTAssertEqual(shadows.farCoverageMeters, 20_000)
        XCTAssertEqual(shadows.mapResolution, defaults.mapResolution)
        XCTAssertEqual(shadows.softness, defaults.softness)
    }

    @MainActor
    func testTheSwitchAloneStillTurnsThemOff() {
        let shadows = ImmersiveMapView().shadows(isEnabled: false).settings.scene.shadows
        XCTAssertFalse(shadows.isEnabled)
        XCTAssertEqual(shadows.nearCoverageMeters, ImmersiveMapSettings.default.scene.shadows.nearCoverageMeters)
    }
}
