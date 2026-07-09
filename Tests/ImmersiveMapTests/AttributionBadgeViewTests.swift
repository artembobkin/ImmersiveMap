// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

@testable import ImmersiveMap
import UIKit
import XCTest

@MainActor
final class AttributionBadgeViewTests: XCTestCase {
    func testDefaultAttributionBadgeIsInteractive() {
        let view = AttributionBadgeView(settings: ImmersiveMapSettings.default.attribution)

        XCTAssertTrue(view.isUserInteractionEnabled)
    }
}

#endif
