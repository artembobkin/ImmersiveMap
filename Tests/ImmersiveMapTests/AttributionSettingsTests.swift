// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class AttributionSettingsTests: XCTestCase {
    /// Встроенные тайлы это планета OpenFreeMap в схеме OpenMapTiles, то есть данные
    /// OpenStreetMap под ODbL. Бейдж обязан называть источник, а не движок.
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

    /// Кастомный провайдер, не объявивший источник, не получает чужую атрибуцию от
    /// движка: пустой бейдж честнее выдуманного копирайта.
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

    /// Смена провайдера меняет текст бейджа, даже если сами `AttributionSettings`
    /// остались прежними, поэтому планировщик обязан пометить домен атрибуции.
    func testProviderChangeMarksAttributionForLiveApply() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings
            .tileProvider(AnyImmersiveMapTileProvider(MapboxTileProvider(accessToken: "token")))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertTrue(plan.changedDomains.contains(.attribution))
    }
}
