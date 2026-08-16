// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class AttributionHiddenNoticeTests: XCTestCase {
    /// The notice is process wide; without the reset another test (or another
    /// run order) would decide the outcome.
    func testShouldLogOncePerProcess() {
        let notice = AttributionHiddenNotice()
        defer {
            notice.reset()
        }

        XCTAssertTrue(notice.shouldLog())
        XCTAssertFalse(notice.shouldLog())

        notice.reset()
        XCTAssertTrue(notice.shouldLog())
    }

    func testDefaultSettingsDoNotWarrantWarning() {
        XCTAssertFalse(AttributionHiddenNotice.isWarningWarranted(for: .default))
    }

    func testHiddenBadgeWarrantsWarning() {
        let settings = ImmersiveMapSettings.default.attributionSettings(isVisible: false)

        XCTAssertTrue(AttributionHiddenNotice.isWarningWarranted(for: settings))
    }

    /// An empty override leaves the badge empty, and that is as invisible as
    /// hiding it.
    func testEmptyAttributionOverrideWarrantsWarning() {
        let settings = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(attributionOverride: ImmersiveMapAttribution.none))

        XCTAssertTrue(AttributionHiddenNotice.isWarningWarranted(for: settings))
    }

    func testExternalDeclarationSilencesHiddenBadge() {
        let settings = ImmersiveMapSettings.default
            .attributionSettings(isVisible: false)
            .attributionProvidedExternally()

        XCTAssertFalse(AttributionHiddenNotice.isWarningWarranted(for: settings))
    }

    /// The declaration alone changes nothing for a visible badge.
    func testVisibleBadgeWithDeclarationStaysSilent() {
        let settings = ImmersiveMapSettings.default.attributionProvidedExternally()

        XCTAssertFalse(AttributionHiddenNotice.isWarningWarranted(for: settings))
    }
}
