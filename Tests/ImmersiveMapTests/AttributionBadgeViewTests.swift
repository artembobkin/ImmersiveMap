// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

@testable import ImmersiveMap
import UIKit
import XCTest

@MainActor
final class AttributionBadgeViewTests: XCTestCase {
    private let boundingSize = CGSize(width: 400, height: 400)

    func testDefaultAttributionBadgeIsInteractive() {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        settings: settings.attribution)

        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertFalse(view.isHidden)
    }

    func testEmptyAttributionHidesBadge() {
        let view = AttributionBadgeView(attribution: .none,
                                        settings: ImmersiveMapSettings.AttributionSettings())

        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.isUserInteractionEnabled)
    }

    /// An empty copyright collapses the second line: the one-line badge must be
    /// strictly shorter than the same badge with a copyright line.
    func testOneLineAttributionIsShorterThanTwoLine() {
        let oneLine = AttributionBadgeView(
            attribution: ImmersiveMapAttribution(title: "© Data", copyright: ""),
            settings: ImmersiveMapSettings.AttributionSettings()
        )
        let twoLine = AttributionBadgeView(
            attribution: ImmersiveMapAttribution(title: "© Data", copyright: "© More data"),
            settings: ImmersiveMapSettings.AttributionSettings()
        )

        let oneLineHeight = oneLine.sizeThatFits(boundingSize).height
        let twoLineHeight = twoLine.sizeThatFits(boundingSize).height

        XCTAssertGreaterThan(oneLineHeight, 0)
        XCTAssertGreaterThan(twoLineHeight, oneLineHeight)
    }

    /// Size presets must order the rendered badge monotonically.
    func testSizePresetsScaleTheBadge() {
        func badgeSize(_ size: ImmersiveMapSettings.AttributionSettings.Size) -> CGSize {
            let settings = ImmersiveMapSettings.default
            let view = AttributionBadgeView(
                attribution: settings.resolvedAttribution,
                settings: ImmersiveMapSettings.AttributionSettings(size: size)
            )
            return view.sizeThatFits(boundingSize)
        }

        let small = badgeSize(.small)
        let regular = badgeSize(.regular)
        let large = badgeSize(.large)

        XCTAssertLessThan(small.height, regular.height)
        XCTAssertLessThan(regular.height, large.height)
        XCTAssertLessThan(small.width, regular.width)
        XCTAssertLessThan(regular.width, large.width)
    }
}

#endif
