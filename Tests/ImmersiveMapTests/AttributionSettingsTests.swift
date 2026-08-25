// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class AttributionSettingsTests: XCTestCase {
    /// The built-in tiles are OpenStreetMap data under ODbL, built by the
    /// ImmersiveMap tile pipeline. The one-line badge names the data, and
    /// only the data: not the engine, and no second party whose schema the
    /// tiles no longer follow.
    func testDefaultAttributionCreditsOpenStreetMapAndNotTheEngine() {
        let attribution = ImmersiveMapSettings.default.resolvedAttribution

        XCTAssertEqual(attribution.title, "© OpenStreetMap")
        XCTAssertTrue(attribution.copyright.isEmpty)
        XCTAssertEqual(attribution.linkURL, URL(string: "https://www.openstreetmap.org/copyright"))
        XCTAssertFalse(attribution.title.contains("ImmersiveMap"))
    }

    /// An app pointing the map at its own data owns the credit: the override
    /// is shown verbatim, nothing added by the engine.
    func testApplicationOverrideWinsOverTheDefaultAttribution() {
        let override = ImmersiveMapAttribution(title: "Custom source",
                                               copyright: "© Custom data",
                                               linkURL: URL(string: "https://example.com/licence"))
        let settings = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(attributionOverride: override))

        XCTAssertEqual(settings.resolvedAttribution, override)
    }

    /// An explicit empty override empties the badge: more honest than a
    /// made-up copyright for data the engine knows nothing about.
    func testEmptyOverrideResolvesToEmpty() {
        let settings = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(attributionOverride: ImmersiveMapAttribution.none))

        XCTAssertTrue(settings.resolvedAttribution.isEmpty)
    }

    /// The badge text changes with the override, so the planner must mark the
    /// attribution domain.
    func testOverrideChangeMarksAttributionForLiveApply() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(
                attributionOverride: ImmersiveMapAttribution(title: "© Example Data",
                                                             copyright: "",
                                                             linkURL: nil)))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertTrue(plan.changedDomains.contains(.attribution))
    }

    /// Badge restyling is host-view chrome: it must apply live, never through
    /// a renderer recreation.
    func testSizeAndPositionChangeIsLiveApplyOnly() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.attributionSettings(size: .large, position: .topLeading)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertTrue(plan.changedDomains.contains(.attribution))
        XCTAssertEqual(plan.actions, [.liveApply])
    }

    /// The partial builder only touches what it is given.
    func testPartialBuilderLeavesOmittedFieldsUnchanged() {
        let override = ImmersiveMapAttribution(title: "Custom", copyright: "")
        let base = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(isVisible: false,
                                                                          textColor: SIMD4<Float>(1, 0, 0, 1),
                                                                          attributionOverride: override))

        let updated = base.attributionSettings(size: .small)

        XCTAssertEqual(updated.attribution.size, .small)
        XCTAssertFalse(updated.attribution.isVisible)
        XCTAssertEqual(updated.attribution.textColor, SIMD4<Float>(1, 0, 0, 1))
        XCTAssertEqual(updated.attribution.attributionOverride, override)
    }

    func testAttributionProvidedExternallySetsOnlyTheFlag() {
        let settings = ImmersiveMapSettings.default.attributionProvidedExternally()

        XCTAssertTrue(settings.attribution.isProvidedExternally)
        XCTAssertEqual(settings.attribution.size, ImmersiveMapSettings.default.attribution.size)
        XCTAssertTrue(settings.attribution.isVisible)
    }
}
