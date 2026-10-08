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
            .shadows(strength: 0.4, coverageCameraDistances: 5)
            .shadows(minimumCoverageMeters: 500)
            .settings
        let shadows = settings.scene.shadows
        let defaults = ImmersiveMapSettings.default.scene.shadows

        XCTAssertTrue(shadows.isEnabled)
        XCTAssertEqual(shadows.minimumCoverageMeters, 500)
        XCTAssertEqual(shadows.strength, 0.4, "Set by the first modifier, kept by the second")
        XCTAssertEqual(shadows.coverageCameraDistances, 5)
        XCTAssertEqual(shadows.mapResolution, defaults.mapResolution)
        XCTAssertEqual(shadows.softness, defaults.softness)
    }

    @MainActor
    func testTheSwitchAloneStillTurnsThemOff() {
        let shadows = ImmersiveMapView().shadows(isEnabled: false).settings.scene.shadows
        XCTAssertFalse(shadows.isEnabled)
        XCTAssertEqual(shadows.minimumCoverageMeters, ImmersiveMapSettings.default.scene.shadows.minimumCoverageMeters)
    }
}
