// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The built-in style's label rules, read through the same `makeStyle` the
/// parser calls: which point features become labels at which tile zoom,
/// and how they rank.
///
/// The rank of a place is the basemap's `population_rank` turned around
/// (lower is more important), and a place without one is the least
/// important thing in its layer. A water name and a POI rank by the tile
/// zoom the basemap ships them from (`min_zoom`).
final class ProtomapsBasemapLabelRulesTests: XCTestCase {
    private let style = ProtomapsBasemapDefaultMapStyle()

    // MARK: Rank

    func testABiggerPopulationRankIsAMoreImportantPlace() {
        XCTAssertLessThan(labelRank(place(populationRank: 17)), labelRank(place(populationRank: 5)))
        XCTAssertLessThan(labelRank(place(kind: "locality", kindDetail: "city", populationRank: 17)),
                          labelRank(place(kind: "locality", kindDetail: "town", populationRank: 5)),
                          "a rank 17 city beats a rank 5 town")
    }

    func testAbsentPopulationRankIsLeastImportantEvenWithLegacySignalsPresent() {
        let noRank = labelRank(place())
        XCTAssertEqual(labelRank(place(extra: ["capital": .string("yes")])), noRank,
                       "capital must not float a rankless feature up")
        XCTAssertEqual(labelRank(place(extra: ["population": .int(13_000_000)])), noRank,
                       "population must not float a rankless feature up")
        XCTAssertGreaterThan(noRank, labelRank(place(populationRank: 0)), "absent rank sits below every ranked place")
    }

    func testTheKindBreaksTiesCountryFirst() {
        let country = labelRank(place(kind: "country", kindDetail: "country", populationRank: 10))
        let region = labelRank(place(kind: "region", kindDetail: "state", populationRank: 10))
        let city = labelRank(place(kind: "locality", kindDetail: "city", populationRank: 10))
        XCTAssertLessThan(country, region)
        XCTAssertLessThan(region, city)
    }

    func testCollisionRankOrdersTheLayersPlacesFirst() {
        let placeStyle = style.makeStyle(data: place(populationRank: 5, tileZoom: 10))
        let waterStyle = style.makeStyle(data: feature(layer: "water", ["kind": .string("lake"), "name": .string("Lake"),
                                                                        "min_zoom": .int(4)], tileZoom: 10))
        let peakStyle = style.makeStyle(data: poi(kind: "peak", minZoom: 9, tileZoom: 10))
        let poiStyle = style.makeStyle(data: poi(kind: "restaurant", minZoom: 13))

        XCTAssertEqual(placeStyle.labelCollisionRank, placeStyle.labelRank, "a place collides at its own rank")
        XCTAssertLessThan(placeStyle.labelCollisionRank, waterStyle.labelCollisionRank)
        XCTAssertLessThan(waterStyle.labelCollisionRank, peakStyle.labelCollisionRank)
        XCTAssertLessThan(peakStyle.labelCollisionRank, poiStyle.labelCollisionRank)
    }

    // MARK: Placement

    /// A water name lies on the water, painted on the map from the zoom the
    /// basemap ships it at; every other label stands on the screen.
    func testAWaterNameIsPaintedOnTheMap() throws {
        let lake = style.makeStyle(data: feature(layer: "water", ["kind": .string("lake"), "name": .string("Lake"),
                                                                  "min_zoom": .int(6)], tileZoom: 8))
        guard case .pointLabel(let label) = lake, case .surface(let placement) = label.placement else {
            return XCTFail("a lake's name is a label painted on the map")
        }
        XCTAssertEqual(placement.referenceZoom, 6.5)
        XCTAssertFalse(placement.isVisible(atZoom: 5.9), "not before the zoom the basemap ships it at")
        XCTAssertTrue(placement.isVisible(atZoom: 6))
        XCTAssertFalse(placement.isVisible(atZoom: 8), "gone before it outgrows the water")
        XCTAssertGreaterThan(placement.letterSpacingEm, 0, "a water name is spaced out")
        XCTAssertEqual(label.text.haloEm, 0, "ink on the water, with no halo")

        guard case .pointLabel(let city) = style.makeStyle(data: place(populationRank: 5, tileZoom: 10)) else {
            return XCTFail("a city is a label")
        }
        XCTAssertEqual(city.placement, .screen)
    }

    /// An ocean the coarsest tiles carry is there from the widest view.
    func testAnOceanNameOfTheCoarsestTilesShowsFromTheWidestView() {
        let ocean = style.makeStyle(data: feature(layer: "water", ["kind": .string("ocean"), "name": .string("Ocean"),
                                                                   "min_zoom": .int(0)], tileZoom: 0))
        guard case .pointLabel(let label) = ocean, case .surface(let placement) = label.placement else {
            return XCTFail("an ocean's name is a label painted on the map")
        }
        XCTAssertTrue(placement.isVisible(atZoom: 0))
    }

    // MARK: Places by zoom

    func testOnlyCountriesAreLabelledAtTheLowestZooms() {
        XCTAssertTrue(isLabel(place(kind: "country", kindDetail: "country", tileZoom: 2)))
        XCTAssertTrue(isLabel(place(kind: "country", kindDetail: "country", tileZoom: 0)))
        XCTAssertFalse(isLabel(place(kind: "locality", kindDetail: "city", populationRank: 17, tileZoom: 2)))
        XCTAssertFalse(isLabel(place(kind: "locality", kindDetail: "city", extra: ["capital": .string("yes")], tileZoom: 2)))
        XCTAssertFalse(isLabel(place(kind: "region", kindDetail: "state", tileZoom: 2)))
    }

    func testZoomThreeAddsCitiesAndCapitalsButNotRegions() {
        XCTAssertTrue(isLabel(place(kind: "locality", kindDetail: "city", tileZoom: 3)))
        XCTAssertTrue(isLabel(place(kind: "locality", kindDetail: "town", extra: ["capital": .string("yes")], tileZoom: 3)))
        XCTAssertFalse(isLabel(place(kind: "region", kindDetail: "state", tileZoom: 3)))
        XCTAssertFalse(isLabel(place(kind: "locality", kindDetail: "town", tileZoom: 3)))
    }

    func testFromZoomFourThePlaceFollowsItsStatedMinimumZoom() {
        XCTAssertTrue(isLabel(place(kind: "region", kindDetail: "state", tileZoom: 4)))
        XCTAssertTrue(isLabel(place(kind: "locality", kindDetail: "town", extra: ["min_zoom": .int(4)], tileZoom: 4)))
        XCTAssertFalse(isLabel(place(kind: "locality", kindDetail: "town", extra: ["min_zoom": .int(7)], tileZoom: 4)))
        XCTAssertFalse(isLabel(place(kind: "neighbourhood", kindDetail: "neighbourhood", tileZoom: 8)),
                       "without a stated zoom a neighbourhood waits for the street zooms")
        XCTAssertTrue(isLabel(place(kind: "neighbourhood", kindDetail: "neighbourhood", tileZoom: 12)))
    }

    func testEveryStatedPlaceIsLabelledFromZoomFive() {
        XCTAssertTrue(isLabel(place(kind: "locality", kindDetail: "town", tileZoom: 5)))
        XCTAssertTrue(isLabel(place(kind: "locality", kindDetail: "village", tileZoom: 12)))
    }

    // MARK: Water names by zoom

    func testOnlyOceansAreLabelledAtTheOverviewZooms() {
        XCTAssertTrue(isLabel(feature(layer: "water", ["kind": .string("ocean"), "name": .string("Sea")], tileZoom: 3)))
        XCTAssertTrue(isLabel(feature(layer: "water", ["kind": .string("ocean"), "name": .string("Sea")], tileZoom: 4)))
        XCTAssertFalse(isLabel(feature(layer: "water", ["kind": .string("lake"), "name": .string("Lake")], tileZoom: 4)))
        XCTAssertTrue(isLabel(feature(layer: "water", ["kind": .string("lake"), "name": .string("Lake")], tileZoom: 5)))
    }

    // MARK: POIs

    func testNoisePoiKindsAreExcluded() {
        for noiseKind in ["bicycle_parking", "waste_basket", "gate", "entrance", "bench", "bus_stop", "parking"] {
            XCTAssertFalse(isLabel(poi(kind: noiseKind, minZoom: 13)),
                           "Kind \(noiseKind) must not become a label")
        }
    }

    func testAPoiWithAnIconIsLabelledFromItsStatedZoom() {
        let restaurant = style.makeStyle(data: poi(kind: "restaurant", minZoom: 15, tileZoom: 14))
        XCTAssertNotNil(restaurant.labelTextStyle)
        XCTAssertEqual(restaurant.labelMinCameraZoom, 15, "the label waits for the camera at the stated zoom")
        let early = style.makeStyle(data: poi(kind: "restaurant", minZoom: 12, tileZoom: 14))
        XCTAssertEqual(early.labelMinCameraZoom, 14, "and never comes before the tile it rides")
    }

    func testAPoiWithoutAStatedZoomWaitsForTheDeepestZoom() {
        XCTAssertEqual(style.makeStyle(data: poi(kind: "restaurant", minZoom: nil)).labelMinCameraZoom,
                       Float(ProtomapsBasemapDefaultMapStyle.poiUnstatedMinimumZoom))
    }

    func testPoiBelowMinimumTileZoomIsExcluded() {
        XCTAssertFalse(isLabel(poi(kind: "restaurant", minZoom: 12, tileZoom: 12)))
        XCTAssertTrue(isLabel(poi(kind: "restaurant", minZoom: 12, tileZoom: 13)))
    }

    func testLandmarksJoinBeforeTheOtherPois() {
        XCTAssertTrue(isLabel(poi(kind: "peak", minZoom: 8, tileZoom: 8)))
        XCTAssertTrue(isLabel(poi(kind: "aerodrome", minZoom: 8, tileZoom: 8)))
        XCTAssertFalse(isLabel(poi(kind: "peak", minZoom: 7, tileZoom: 7)))
        XCTAssertEqual(style.makeStyle(data: poi(kind: "aerodrome", minZoom: 5, tileZoom: 9)).labelMinCameraZoom, 9,
                       "an airport is at the floor of its tile, whatever the basemap states")
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

    private func place(kind: String = "locality",
                       kindDetail: String = "city",
                       populationRank: Int? = nil,
                       extra: [String: MvtValue] = [:],
                       tileZoom: Int = 10) -> DetFeatureStyleData {
        var properties: [String: MvtValue] = ["name": .string("Test"), "kind": .string(kind),
                                              "kind_detail": .string(kindDetail)]
        if let populationRank {
            properties["population_rank"] = .int(Int64(populationRank))
        }
        properties.merge(extra) { _, new in new }
        return feature(layer: "places", properties, tileZoom: tileZoom)
    }

    private func poi(kind: String, minZoom: Int?, tileZoom: Int = 14) -> DetFeatureStyleData {
        var properties: [String: MvtValue] = ["name": .string("Test"), "kind": .string(kind)]
        if let minZoom {
            properties["min_zoom"] = .int(Int64(minZoom))
        }
        return feature(layer: "pois", properties, tileZoom: tileZoom)
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
