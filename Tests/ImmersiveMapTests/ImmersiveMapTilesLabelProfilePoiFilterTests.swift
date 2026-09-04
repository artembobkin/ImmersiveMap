// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// Hard filters of the OpenMapTiles profile's poi layer: street furniture and
/// the local-rank tail never become labels at all.
final class ImmersiveMapTilesLabelProfilePoiFilterTests: XCTestCase {
    private let profile = ImmersiveMapTilesVectorTileLabelProviderProfile(settings: .default)

    func testNoisePoiClassesAreExcluded() {
        for noiseClass in ["bicycle_parking", "waste_basket", "gate", "entrance", "bench"] {
            XCTAssertFalse(includesPoi(className: noiseClass, rank: 1),
                           "Class \(noiseClass) must not become a label")
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
        var properties: [String: MvtValue] = [:]
        let nameValue = MvtValue.string("Test")
        properties["name"] = nameValue
        let classValue = MvtValue.string(className)
        properties["class"] = classValue
        if let rank {
            let rankValue = MvtValue.int(Int64(rank))
            properties["rank"] = rankValue
        }
        return profile.includesBasePointLabel(layerName: "poi",
                                              properties: properties,
                                              tileZoom: tileZoom,
                                              sortKey: rank ?? 1_000)
    }
}
