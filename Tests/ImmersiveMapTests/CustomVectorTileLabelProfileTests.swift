// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CustomVectorTileLabelProfileTests: XCTestCase {
    func testCustomProviderUsesConfiguredLabelProfile() {
        let provider = VectorTileProvider(
            id: "custom",
            tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!),
            labelProfile: ImmersiveMapVectorTileLabelProfile(
                textKeys: ["title"],
                rankKeys: ["priority"],
                kindKeys: ["category"],
                pointLabelLayers: ["custom_label"],
                houseNumberLayers: ["address_label"],
                houseNumberTextKeys: ["number"]
            )
        )

        let profile = AnyImmersiveMapTileProvider(provider).makeLabelProviderProfile(settings: .default)

        XCTAssertEqual(profile.sortKey(properties: ["priority": intValue(7)]), 7)
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "custom_label",
                                                     properties: ["title": stringValue("Cafe")],
                                                     tileZoom: 15,
                                                     sortKey: 7))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "other_label",
                                                      properties: ["title": stringValue("Cafe")],
                                                      tileZoom: 15,
                                                      sortKey: 7))
        XCTAssertEqual(profile.normalizedKind(layerName: "custom_label",
                                              properties: ["category": stringValue("Food")]),
                       "custom_label:food")
        XCTAssertTrue(profile.isHouseNumberLayer("address_label"))
    }

    func testCustomProviderLabelProfileParticipatesInConfigurationFingerprint() {
        let defaultProvider = VectorTileProvider(
            id: "custom",
            tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!)
        )
        let customProvider = VectorTileProvider(
            id: "custom",
            tileSource: .url(URL(string: "https://example.com/api/v1/map/tiles")!),
            labelProfile: ImmersiveMapVectorTileLabelProfile(textKeys: ["title"])
        )

        XCTAssertNotEqual(defaultProvider.configurationFingerprint, customProvider.configurationFingerprint)
    }

    func testCustomLabelProfileResolvesTextFromCustomKey() {
        let profile = GenericVectorTileLabelProviderProfile(
            providerID: "custom",
            settings: .default,
            profile: ImmersiveMapVectorTileLabelProfile(textKeys: ["title"])
        )
        let decisionEngine = VectorTileLabelDecisionEngine(
            profile: profile,
            textResolver: VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        )
        let feature = VectorTileLabelFeature(
            providerID: "custom",
            tile: Tile(x: 1, y: 2, z: 10),
            layerName: "custom_label",
            featureID: nil,
            anchor: SIMD2<Int16>(100, 200),
            properties: ["title": stringValue("Custom Cafe")]
        )
        let style = LabelTextStyle(
            key: 1,
            fillColor: SIMD3<Float>(0.1, 0.1, 0.1),
            strokeColor: SIMD3<Float>(1.0, 1.0, 1.0),
            strokeWidthPx: 2,
            sizePx: 12,
            weight: .thin
        )

        let decision = decisionEngine.makePointLabelDecision(feature: feature,
                                                             style: style,
                                                             poiIcon: nil as PoiSpriteIcon?)

        XCTAssertEqual(decision?.text, "Custom Cafe")
    }
}

private func stringValue(_ value: String) -> VectorTile_Tile.Value {
    var tileValue = VectorTile_Tile.Value()
    tileValue.stringValue = value
    return tileValue
}

private func intValue(_ value: Int64) -> VectorTile_Tile.Value {
    var tileValue = VectorTile_Tile.Value()
    tileValue.intValue = value
    return tileValue
}
