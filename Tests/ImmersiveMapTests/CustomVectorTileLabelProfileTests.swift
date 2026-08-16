// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CustomVectorTileLabelProfileTests: XCTestCase {
    func testCustomStyleUsesConfiguredLabelProfile() {
        let mapStyle = VectorTileMapStyle(
            style: BasicVectorTileStyle(cacheFingerprint: 1),
            labelProfile: ImmersiveMapVectorTileLabelProfile(
                textKeys: ["title"],
                rankKeys: ["priority"],
                kindKeys: ["category"],
                pointLabelLayers: ["custom_label"],
                houseNumberLayers: ["address_label"],
                houseNumberTextKeys: ["number"]
            )
        )

        let profile = AnyImmersiveMapMapStyle(mapStyle).makeLabelProviderProfile(settings: .default)

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

    func testCustomLabelProfileParticipatesInStyleConfigurationFingerprint() {
        let defaultStyle = VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1))
        let customStyle = VectorTileMapStyle(
            style: BasicVectorTileStyle(cacheFingerprint: 1),
            labelProfile: ImmersiveMapVectorTileLabelProfile(textKeys: ["title"])
        )

        XCTAssertNotEqual(defaultStyle.configurationFingerprint, customStyle.configurationFingerprint)
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
            haloEm: 0.15,
            sizePoints: 12,
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
