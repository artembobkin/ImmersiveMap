// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class AttributionSettingsTests: XCTestCase {
    func testDefaultAttributionLinksToArtemBobkinXAccount() {
        let attribution = ImmersiveMapSettings.default.attribution

        XCTAssertEqual(attribution.linkURL, URL(string: "https://x.com/BobkinArtem"))
    }
}
