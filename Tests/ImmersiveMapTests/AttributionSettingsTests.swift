// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class AttributionSettingsTests: XCTestCase {
    /// The built-in tiles are OpenStreetMap data under ODbL, built by the
    /// ImmersiveMap tile pipeline. The badge names the data first, and no
    /// second party whose schema the tiles no longer follow. The overview
    /// the engine ships adds its own credit after it, and the engine's own
    /// closes the line, a courtesy the app may drop.
    func testDefaultAttributionCreditsOpenStreetMapFirstAndTheEngineLast() {
        let attribution = ImmersiveMapSettings.default.resolvedAttribution

        XCTAssertEqual(attribution.credits.first?.text, "© OpenStreetMap")
        XCTAssertNil(attribution.credits.first?.zoomRange, "The tiles are on screen at every zoom")
        XCTAssertEqual(attribution.linkURL, URL(string: "https://www.openstreetmap.org/copyright"))
        XCTAssertEqual(attribution.credits.last, ImmersiveMapAttribution.engineCredit)
        XCTAssertNil(attribution.credits.last?.zoomRange, "The engine's credit stays at every zoom")
        XCTAssertEqual(ImmersiveMapTilesService.attribution.credits.count, 1,
                       "The service credits its own data alone")

        let plain = ImmersiveMapSettings.default.attributionSettings(showsEngineCredit: false).resolvedAttribution
        XCTAssertFalse(plain.credits.contains { $0.text.contains("ImmersiveMap") })
        XCTAssertEqual(plain.credits.first?.text, "© OpenStreetMap")
    }

    /// The biomes of the overview are CC BY 4.0 and credited while they
    /// are on screen: the camera zooms up to the one the built-in style has
    /// faded them out by, and not past it, where the map draws none of
    /// them.
    func testTheOverviewIsCreditedAtTheZoomsItIsDrawnAt() {
        let attribution = ImmersiveMapSettings.default.resolvedAttribution

        XCTAssertEqual(attribution.credits.count, 4)
        let overview = attribution.credits[1]
        XCTAssertEqual(overview.text, "Biomes © RESOLVE, CC BY 4.0")
        XCTAssertEqual(overview.zoomRange, 0..<8)
        XCTAssertEqual(attribution.credits(atZoom: 0).count, 3)
        XCTAssertEqual(attribution.credits(atZoom: 7.9).count, 3)
        XCTAssertEqual(attribution.credits(atZoom: 8).map(\.text), ["© OpenStreetMap", "Powered by ImmersiveMap"])
        XCTAssertEqual(attribution.credits(atZoom: 9.9).map(\.text), ["© OpenStreetMap", "Powered by ImmersiveMap"])
        XCTAssertEqual(attribution.credits(atZoom: nil).count, 4, "Before the camera is placed every credit shows")
    }

    /// The credit's zoom follows the setting, for a theme that keeps the
    /// biomes to another zoom, and goes with the overview when the
    /// overview is off.
    func testTheOverviewCreditFollowsItsSetting() {
        let raised = ImmersiveMapSettings.default.overviewTiles(creditMaximumZoom: 10).resolvedAttribution
        XCTAssertEqual(raised.credits[1].zoomRange, 0..<10)
        XCTAssertTrue(raised.credits(atZoom: 9).contains { $0.text.hasPrefix("Biomes") })

        let off = ImmersiveMapSettings.default.overviewTiles(isEnabled: false).resolvedAttribution
        XCTAssertEqual(off.credits.map(\.text), ["© OpenStreetMap", "© Mapterhorn", "Powered by ImmersiveMap"])
    }

    /// Mapterhorn's terrain asks for a credit, shown at the camera zooms
    /// the relief stands out of the plane at and not below or past them,
    /// where no terrain is read.
    func testTheTerrainIsCreditedAtTheZoomsTheReliefRisesAt() {
        let attribution = ImmersiveMapSettings.default.resolvedAttribution

        let terrain = attribution.credits[2]
        XCTAssertEqual(terrain.text, "© Mapterhorn")
        XCTAssertEqual(terrain.zoomRange, 10..<13.7)
        XCTAssertEqual(attribution.credits(atZoom: 9.9).map(\.text), ["© OpenStreetMap", "Powered by ImmersiveMap"])
        XCTAssertEqual(attribution.credits(atZoom: 12.2).map(\.text), ["© OpenStreetMap", "© Mapterhorn", "Powered by ImmersiveMap"])
        XCTAssertEqual(attribution.credits(atZoom: 13.7).map(\.text), ["© OpenStreetMap", "Powered by ImmersiveMap"])
    }

    /// The terrain's credit follows the relief's zooms, and goes with the
    /// relief when it is off, never rises, or reads another source.
    func testTheTerrainCreditFollowsTheRelief() {
        var settings = ImmersiveMapSettings.default
        settings.tiles.groundRelief.appearZoom = 8
        settings.tiles.groundRelief.collapseZoom = 15
        XCTAssertEqual(settings.resolvedAttribution.credits.first { $0.text == "© Mapterhorn" }?.zoomRange, 8..<15)

        var off = ImmersiveMapSettings.default
        off.tiles.groundRelief.isEnabled = false
        XCTAssertFalse(off.resolvedAttribution.credits.contains { $0.text == "© Mapterhorn" })

        var neverRises = ImmersiveMapSettings.default
        neverRises.tiles.groundRelief.appearZoom = 14
        neverRises.tiles.groundRelief.collapseZoom = 14
        XCTAssertFalse(neverRises.resolvedAttribution.credits.contains { $0.text == "© Mapterhorn" })

        var elsewhere = ImmersiveMapSettings.default
        elsewhere.tiles.groundRelief.tileURLTemplate = "https://example.com/terrain/{z}/{x}/{y}.png"
        XCTAssertFalse(elsewhere.resolvedAttribution.credits.contains { $0.text == "© Mapterhorn" })
    }

    /// An app pointing the map at its own data owns the credit of that
    /// data: the override leads the line. The overview is still laid into
    /// its tiles and the relief still reads Mapterhorn's terrain, so their
    /// credits follow it.
    func testApplicationOverrideLeadsTheLineAndTheOverviewFollows() {
        let override = ImmersiveMapAttribution(credits: [.init("Custom source"), .init("© Custom data")],
                                               linkURL: URL(string: "https://example.com/licence"))
        let settings = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(attributionOverride: override))

        let resolved = settings.resolvedAttribution
        XCTAssertEqual(resolved.linkURL, override.linkURL)
        XCTAssertEqual(resolved.credits.map(\.text), ["Custom source", "© Custom data", "Biomes © RESOLVE, CC BY 4.0", "© Mapterhorn", "Powered by ImmersiveMap"])

        let withoutOverview = settings.overviewTiles(isEnabled: false).resolvedAttribution
        XCTAssertEqual(withoutOverview.credits.map(\.text), ["Custom source", "© Custom data", "© Mapterhorn", "Powered by ImmersiveMap"])
    }

    /// An explicit empty override empties the badge: the app took the whole
    /// credit over, the overview's with it. More honest than a made-up
    /// credit for data the engine knows nothing about.
    func testEmptyOverrideResolvesToEmpty() {
        let settings = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(attributionOverride: ImmersiveMapAttribution.none))

        XCTAssertTrue(settings.resolvedAttribution.isEmpty)
        XCTAssertTrue(settings.resolvedAttribution.credits.isEmpty)
    }

    /// A credit with no words is no credit, and a credit's zoom range is a
    /// half-open range of camera zoom.
    func testCreditsAtAZoomDropTheEmptyAndTheOutOfRange() {
        let attribution = ImmersiveMapAttribution(credits: [
            .init("Always"),
            .init(""),
            .init("Low", zoomRange: 0..<5),
            .init("High", zoomRange: 5..<20)
        ])

        XCTAssertTrue(ImmersiveMapAttribution(credits: [.init(""), .init("")]).isEmpty)
        XCTAssertFalse(attribution.isEmpty)
        XCTAssertEqual(attribution.credits(atZoom: 4.99).map(\.text), ["Always", "Low"])
        XCTAssertEqual(attribution.credits(atZoom: 5).map(\.text), ["Always", "High"])
        XCTAssertEqual(attribution.credits(atZoom: 20).map(\.text), ["Always"])
        XCTAssertEqual(attribution.credits(atZoom: nil).map(\.text), ["Always", "Low", "High"])
    }

    /// The badge text changes with the override, so the planner must mark the
    /// attribution domain.
    func testOverrideChangeMarksAttributionForLiveApply() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(
                attributionOverride: ImmersiveMapAttribution("© Example Data")))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertTrue(plan.changedDomains.contains(.attribution))
    }

    /// The overview credit's zoom is badge text: applied in place, no
    /// re-parse, the tiles do not change.
    func testOverviewCreditZoomChangeIsLiveApplyOnly() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.overviewTiles(creditMaximumZoom: 9)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.attribution])
        XCTAssertEqual(plan.actions, [.liveApply])
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
        let override = ImmersiveMapAttribution("Custom")
        let base = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(isVisible: false,
                                                                          textColor: SIMD4<Float>(1, 0, 0, 1),
                                                                          attributionOverride: override))

        let updated = base.attributionSettings(size: .small)

        XCTAssertEqual(updated.attribution.size, .small)
        XCTAssertFalse(updated.attribution.isVisible)
        XCTAssertEqual(updated.attribution.textColor, SIMD4<Float>(1, 0, 0, 1))
        XCTAssertEqual(updated.attribution.attributionOverride, override)
        XCTAssertFalse(updated.attribution.emphasizesLeadingCredit, "Off by default: one list")
        XCTAssertTrue(updated.attributionSettings(emphasizesLeadingCredit: true).attribution.emphasizesLeadingCredit)
        XCTAssertEqual(updated.attributionSettings(emphasizesLeadingCredit: true).attribution.size, .small)
    }

    func testAttributionProvidedExternallySetsOnlyTheFlag() {
        let settings = ImmersiveMapSettings.default.attributionProvidedExternally()

        XCTAssertTrue(settings.attribution.isProvidedExternally)
        XCTAssertEqual(settings.attribution.size, ImmersiveMapSettings.default.attribution.size)
        XCTAssertTrue(settings.attribution.isVisible)
    }
}
