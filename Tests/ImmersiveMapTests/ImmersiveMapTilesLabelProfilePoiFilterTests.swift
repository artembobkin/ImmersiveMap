// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Жёсткие фильтры poi-слоя профиля OpenMapTiles: уличная фурнитура и хвост
/// локального ранга не становятся подписями вовсе.
final class ImmersiveMapTilesLabelProfilePoiFilterTests: XCTestCase {
    private let profile = ImmersiveMapTilesVectorTileLabelProviderProfile(settings: .default)

    func testNoisePoiClassesAreExcluded() {
        for noiseClass in ["bicycle_parking", "waste_basket", "gate", "entrance", "bench"] {
            XCTAssertFalse(includesPoi(className: noiseClass, rank: 1),
                           "Класс \(noiseClass) не должен становиться подписью")
        }
    }

    func testRegularPoiClassPassesWithinRankCap() {
        XCTAssertTrue(includesPoi(className: "restaurant", rank: 4))
        XCTAssertTrue(includesPoi(className: "restaurant", rank: 64))
    }

    func testDeepRankTailIsExcluded() {
        XCTAssertFalse(includesPoi(className: "restaurant", rank: 65))
        XCTAssertFalse(includesPoi(className: "restaurant", rank: 120))
    }

    func testPoiWithoutRankPasses() {
        XCTAssertTrue(includesPoi(className: "restaurant", rank: nil))
    }

    func testPoiBelowMinimumTileZoomIsExcluded() {
        XCTAssertFalse(includesPoi(className: "restaurant", rank: 1, tileZoom: 12))
    }

    private func includesPoi(className: String, rank: Int?, tileZoom: Int = 14) -> Bool {
        var properties: [String: VectorTile_Tile.Value] = [:]
        var nameValue = VectorTile_Tile.Value()
        nameValue.stringValue = "Test"
        properties["name"] = nameValue
        var classValue = VectorTile_Tile.Value()
        classValue.stringValue = className
        properties["class"] = classValue
        if let rank {
            var rankValue = VectorTile_Tile.Value()
            rankValue.intValue = Int64(rank)
            properties["rank"] = rankValue
        }
        return profile.includesBasePointLabel(layerName: "poi",
                                              properties: properties,
                                              tileZoom: tileZoom,
                                              sortKey: rank ?? 1_000)
    }
}
