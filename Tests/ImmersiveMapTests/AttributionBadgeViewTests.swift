// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

@testable import ImmersiveMap
import UIKit
import XCTest

@MainActor
final class AttributionBadgeViewTests: XCTestCase {
    func testDefaultAttributionBadgeIsInteractive() {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        isVisible: settings.attribution.isVisible)

        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertFalse(view.isHidden)
    }

    func testEmptyAttributionHidesBadge() {
        let view = AttributionBadgeView(attribution: .none, isVisible: true)

        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.isUserInteractionEnabled)
    }
}

#endif
