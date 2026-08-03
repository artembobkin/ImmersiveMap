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
        XCTAssertEqual(shadows.strength, 0.5)
        XCTAssertEqual(shadows.mapResolution, 2048)
        XCTAssertEqual(shadows.coverageCameraDistances, 16.0)
    }
}
