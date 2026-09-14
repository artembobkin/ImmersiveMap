// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// A custom schema reading states which properties carry a label's text
/// and which layers are house numbers; the custom style states the
/// namespace its labels are identified in and how important each is.
final class CustomVectorTileStyleLabelTests: XCTestCase {
    func testTextComesFromTheStyleTextKeys() {
        let decision = decide(feature(layer: "custom_label", ["title": .string("Custom Cafe")]))

        XCTAssertEqual(decision?.text, "Custom Cafe")
    }

    func testTheLanguageChainIsReadBeforeTheStyleTextKeys() {
        let decision = decide(feature(layer: "custom_label",
                                      ["name_en": .string("Cafe"), "title": .string("Custom Cafe")]))

        XCTAssertEqual(decision?.text, "Cafe")
    }

    func testAFeatureWithoutTextIsNoLabel() {
        XCTAssertNil(decide(feature(layer: "custom_label", ["category": .string("food")])))
    }

    func testHouseNumberLayersReadTheNumber() {
        let decision = decide(feature(layer: "address_label", ["number": .string("12b")]))

        XCTAssertEqual(decision?.text, "12b")
    }

    func testTheStyleRankAndCollisionRankReachTheDecision() {
        let decision = decide(feature(layer: "custom_label", ["title": .string("Custom Cafe")]))

        XCTAssertEqual(decision?.priority.visibilityRank, 7)
        XCTAssertEqual(decision?.priority.deduplicationRank, 7)
        XCTAssertEqual(decision?.priority.drawRank, 7)
        XCTAssertEqual(decision?.priority.collisionRank, 70)
    }

    func testLabelsAreIdentifiedInTheStyleNamespaceByFeatureID() {
        let decision = decide(feature(layer: "custom_label", ["title": .string("Custom Cafe")], featureID: 42))

        XCTAssertEqual(decision?.identity,
                       .styleFeature(styleID: "custom", layerName: "custom_label", featureID: 42))
    }

    func testAFeatureWithoutAnIDIsIdentifiedByItsTile() {
        let decision = decide(feature(layer: "custom_label", ["title": .string("Custom Cafe")]))

        XCTAssertEqual(decision?.identity,
                       .tileLocal(tile: Tile(x: 1, y: 2, z: 10),
                                  layerName: "custom_label",
                                  text: "Custom Cafe",
                                  anchor: SIMD2<Int16>(100, 200)))
    }

    func testAStyleCanOptOutOfFeatureIdentity() {
        let decision = decide(feature(layer: "custom_label", ["title": .string("Custom Cafe")], featureID: 42),
                              style: CustomLabelTestStyle(labelsUseFeatureIdentity: false))

        XCTAssertEqual(decision?.identity,
                       .tileLocal(tile: Tile(x: 1, y: 2, z: 10),
                                  layerName: "custom_label",
                                  text: "Custom Cafe",
                                  anchor: SIMD2<Int16>(100, 200)))
    }

    func testTheStyleFingerprintIsTheMapStyleFingerprint() {
        let one = VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 1))
        let two = VectorTileMapStyle(style: BasicVectorTileStyle(cacheFingerprint: 2))

        XCTAssertNotEqual(one.configurationFingerprint, two.configurationFingerprint)
    }

    // MARK: Helpers

    private func decide(_ feature: VectorTileLabelFeature,
                        style: CustomLabelTestStyle = CustomLabelTestStyle()) -> VectorTileLabelDecision? {
        let decisions = TileLabelDecisions(schema: CustomLabelTestSchema(),
                                           style: style,
                                           glyphCoverage: .legacyAtlasForTests,
                                           language: .english,
                                           fallbackPolicy: .international)
        let featureStyle = style.makeStyle(for: ImmersiveMapFeatureStyleContext(
            styleID: style.styleID,
            data: DetFeatureStyleData(layerName: feature.layerName,
                                      properties: feature.properties,
                                      tile: feature.tile,
                                      facts: .none,
                                      geometryType: .point)))
        return decisions.pointLabelDecision(feature: feature, style: featureStyle, poiIcon: nil)
    }

    private func feature(layer: String,
                         _ properties: [String: MvtValue],
                         featureID: UInt64? = nil) -> VectorTileLabelFeature {
        VectorTileLabelFeature(styleID: "custom",
                               tile: Tile(x: 1, y: 2, z: 10),
                               layerName: layer,
                               featureID: featureID,
                               anchor: SIMD2<Int16>(100, 200),
                               properties: properties)
    }
}

private struct CustomLabelTestSchema: ImmersiveMapTileSchema {
    let cacheFingerprint: UInt32 = 1
    let labelTextKeys = ["title"]
    let houseNumberLayers: Set<String> = ["address_label"]
    let houseNumberTextKeys = ["number"]

    func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts {
        .none
    }
}

private struct CustomLabelTestStyle: ImmersiveMapVectorTileStyle {
    var labelsUseFeatureIdentity = true

    let cacheFingerprint: UInt32 = 1
    let styleID = "custom"

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        let text = LabelTextStyle(fillColor: SIMD3<Float>(0.1, 0.1, 0.1),
                                  strokeColor: SIMD3<Float>(1, 1, 1),
                                  haloEm: 0.15,
                                  sizePoints: 12,
                                  weight: .thin)
        switch feature.layerName {
        case "custom_label":
            return .pointLabel(key: 70, text, rank: 7, collisionRank: 70)
        case "address_label":
            return .pointLabel(key: 71, text, rank: 100)
        default:
            return .hidden
        }
    }
}
