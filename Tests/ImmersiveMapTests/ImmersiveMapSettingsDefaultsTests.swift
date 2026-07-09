// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapSettingsDefaultsTests: XCTestCase {
    func testDefaultLabelLanguageIsEnglish() {
        XCTAssertEqual(ImmersiveMapSettings.default.labels.language, .english)
    }
}
