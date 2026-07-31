// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class AttributionSettingsTests: XCTestCase {
    /// The built-in tiles are the OpenFreeMap planet in the OpenMapTiles schema,
    /// i.e. OpenStreetMap data under ODbL. The badge must name the source, not the engine.
    func testDefaultAttributionCreditsOpenStreetMapAndNotTheEngine() {
        let attribution = ImmersiveMapSettings.default.resolvedAttribution

        XCTAssertTrue(attribution.title.contains("OpenStreetMap"))
        XCTAssertTrue(attribution.copyright.contains("OpenMapTiles"))
        XCTAssertTrue(attribution.copyright.contains("OpenFreeMap"))
        XCTAssertEqual(attribution.linkURL, URL(string: "https://www.openstreetmap.org/copyright"))
        XCTAssertFalse(attribution.title.contains("ImmersiveMap"))
        XCTAssertFalse(attribution.copyright.contains("ImmersiveMap"))
    }

    func testMapboxProviderCreditsMapboxAndOpenStreetMap() {
        let settings = ImmersiveMapSettings.default
            .tileProvider(AnyImmersiveMapTileProvider(MapboxTileProvider(accessToken: "token")))

        let attribution = settings.resolvedAttribution

        XCTAssertTrue(attribution.title.contains("Mapbox"))
        XCTAssertTrue(attribution.title.contains("OpenStreetMap"))
    }

    /// A custom provider that declares no source gets no third-party attribution
    /// from the engine: an empty badge is more honest than a made-up copyright.
    func testCustomProviderWithoutAttributionResolvesToEmpty() {
        let provider = VectorTileProvider(id: "custom",
                                          tileSource: .immersiveMapTiles(tileBaseURL: URL(string: "https://example.com/tiles")!,
                                                                         apiKey: nil))
        let settings = ImmersiveMapSettings.default
            .tileProvider(AnyImmersiveMapTileProvider(provider))

        XCTAssertTrue(settings.resolvedAttribution.isEmpty)
    }

    func testApplicationOverrideWinsOverProviderAttribution() {
        let override = ImmersiveMapAttribution(title: "Custom source",
                                               copyright: "© Custom data",
                                               linkURL: URL(string: "https://example.com/licence"))
        let settings = ImmersiveMapSettings.default
            .attributionSettings(ImmersiveMapSettings.AttributionSettings(attributionOverride: override))

        XCTAssertEqual(settings.resolvedAttribution, override)
    }

    /// Changing the provider changes the badge text even if the `AttributionSettings`
    /// themselves stayed the same, so the planner must mark the attribution domain.
    func testProviderChangeMarksAttributionForLiveApply() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings
            .tileProvider(AnyImmersiveMapTileProvider(MapboxTileProvider(accessToken: "token")))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertTrue(plan.changedDomains.contains(.attribution))
    }
}
