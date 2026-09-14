// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The built-in style's label rules, read through the same `makeStyle` the
/// parser calls: which point features become labels at which tile zoom,
/// and how they rank.
///
/// The rank pins the one-number label-priority contract the tiles follow:
/// `rank` is the whole signal, lower is more important, and a feature
/// without a rank is the least important thing in its layer. There is no
/// second mechanism to reconcile: the tiles bake population and capital
/// status into the rank at build time, so the style must not resurrect
/// them as fallbacks.
final class ImmersiveMapTilesLabelRulesTests: XCTestCase {
    private let style = ImmersiveMapTilesDefaultMapStyle()

    // MARK: Rank

    func testRankIsTheLabelRank() {
        XCTAssertEqual(labelRank(place(rank: 1)), 1)
        XCTAssertEqual(labelRank(place(rank: 7)), 7)
    }

    func testAbsentRankIsLeastImportantEvenWithLegacySignalsPresent() {
        let noRank = labelRank(place())
        XCTAssertEqual(labelRank(place(extra: ["capital": .int(2)])), noRank,
                       "capital must not float a rankless feature up")
        XCTAssertEqual(labelRank(place(extra: ["population": .int(13_000_000)])), noRank,
                       "population must not float a rankless feature up")
        XCTAssertGreaterThan(noRank, 10, "absent rank sits below every ranked place (1..10)")
    }

    func testRankOutranksAnyLegacySignal() {
        let rankedVillage = labelRank(place(rank: 9))
        let ranklessMetropolis = labelRank(place(extra: ["population": .int(13_000_000)]))
        XCTAssertLessThan(rankedVillage, ranklessMetropolis)
    }

    func testCollisionRankOrdersTheLayersPlacesFirst() {
        let placeStyle = style.makeStyle(data: place(rank: 5, tileZoom: 10))
        let waterStyle = style.makeStyle(data: feature(layer: "water_name", ["class": .string("lake"), "rank": .int(1)], tileZoom: 10))
        let peakStyle = style.makeStyle(data: feature(layer: "mountain_peak", ["rank": .int(1)], tileZoom: 10))
        let poiStyle = style.makeStyle(data: poi(className: "restaurant", rank: 1))

        XCTAssertEqual(placeStyle.labelCollisionRank, 5, "a place collides at its own rank")
        XCTAssertLessThan(placeStyle.labelCollisionRank, waterStyle.labelCollisionRank)
        XCTAssertLessThan(waterStyle.labelCollisionRank, peakStyle.labelCollisionRank)
        XCTAssertLessThan(peakStyle.labelCollisionRank, poiStyle.labelCollisionRank)
    }

    // MARK: Places by zoom

    func testOnlyContinentsCountriesAndOceansAreLabelledAtTheLowestZooms() {
        XCTAssertTrue(isLabel(place(className: "country", tileZoom: 2)))
        XCTAssertTrue(isLabel(place(className: "ocean", tileZoom: 0)))
        XCTAssertFalse(isLabel(place(className: "city", rank: 1, tileZoom: 2)))
        XCTAssertFalse(isLabel(place(className: "city", extra: ["capital": .int(2)], tileZoom: 2)))
    }

    func testZoomThreeAddsCitiesAndCapitalsButNotStates() {
        XCTAssertTrue(isLabel(place(className: "city", tileZoom: 3)))
        XCTAssertTrue(isLabel(place(className: "state", extra: ["capital": .int(4)], tileZoom: 3)))
        XCTAssertFalse(isLabel(place(className: "state", tileZoom: 3)))
        XCTAssertFalse(isLabel(place(className: "town", tileZoom: 3)))
    }

    func testZoomFourAddsStatesAndProvinces() {
        XCTAssertTrue(isLabel(place(className: "state", tileZoom: 4)))
        XCTAssertTrue(isLabel(place(className: "province", tileZoom: 4)))
        XCTAssertFalse(isLabel(place(className: "town", tileZoom: 4)))
        XCTAssertTrue(isLabel(place(className: "town", extra: ["capital": .int(4)], tileZoom: 4)))
    }

    func testEveryPlaceIsLabelledFromZoomFive() {
        XCTAssertTrue(isLabel(place(className: "town", tileZoom: 5)))
        XCTAssertTrue(isLabel(place(className: "village", tileZoom: 12)))
    }

    // MARK: Water names by zoom

    func testOnlyOceansAndSeasAreLabelledAtTheOverviewZooms() {
        XCTAssertTrue(isLabel(feature(layer: "water_name", ["class": .string("ocean")], tileZoom: 3)))
        XCTAssertTrue(isLabel(feature(layer: "water_name", ["class": .string("sea")], tileZoom: 4)))
        XCTAssertFalse(isLabel(feature(layer: "water_name", ["class": .string("lake")], tileZoom: 4)))
        XCTAssertTrue(isLabel(feature(layer: "water_name", ["class": .string("lake")], tileZoom: 5)))
    }

    // MARK: POIs

    func testNoisePoiClassesAreExcluded() {
        for noiseClass in ["bicycle_parking", "waste_basket", "gate", "entrance", "bench"] {
            XCTAssertFalse(isLabel(poi(className: noiseClass, rank: 1)),
                           "Class \(noiseClass) must not become a label")
        }
    }

    func testRegularPoiClassPassesWithinRankCap() {
        XCTAssertTrue(isLabel(poi(className: "restaurant", rank: 4)))
        XCTAssertTrue(isLabel(poi(className: "restaurant", rank: 64)))
    }

    func testDeepRankTailIsExcluded() {
        XCTAssertFalse(isLabel(poi(className: "restaurant", rank: 65)))
        XCTAssertFalse(isLabel(poi(className: "restaurant", rank: 120)))
    }

    func testPoiWithoutRankPasses() {
        XCTAssertTrue(isLabel(poi(className: "restaurant", rank: nil)))
    }

    func testPoiBelowMinimumTileZoomIsExcluded() {
        XCTAssertFalse(isLabel(poi(className: "restaurant", rank: 1, tileZoom: 12)))
    }

    // MARK: Helpers

    private func labelRank(_ data: DetFeatureStyleData) -> Int {
        style.makeStyle(data: data).labelRank
    }

    /// A feature the style labels comes back with a text style; one it
    /// excludes comes back hidden, with none.
    private func isLabel(_ data: DetFeatureStyleData) -> Bool {
        style.makeStyle(data: data).labelTextStyle != nil
    }

    private func place(className: String = "city",
                       rank: Int? = nil,
                       extra: [String: MvtValue] = [:],
                       tileZoom: Int = 10) -> DetFeatureStyleData {
        var properties: [String: MvtValue] = ["name": .string("Test"), "class": .string(className)]
        if let rank {
            properties["rank"] = .int(Int64(rank))
        }
        properties.merge(extra) { _, new in new }
        return feature(layer: "place", properties, tileZoom: tileZoom)
    }

    private func poi(className: String, rank: Int?, tileZoom: Int = 14) -> DetFeatureStyleData {
        var properties: [String: MvtValue] = ["name": .string("Test"), "class": .string(className)]
        if let rank {
            properties["rank"] = .int(Int64(rank))
        }
        return feature(layer: "poi", properties, tileZoom: tileZoom)
    }

    private func feature(layer: String,
                         _ properties: [String: MvtValue],
                         tileZoom: Int) -> DetFeatureStyleData {
        DetFeatureStyleData(layerName: layer,
                            properties: properties,
                            tile: Tile(x: 0, y: 0, z: tileZoom),
                            geometryType: .point)
    }
}
