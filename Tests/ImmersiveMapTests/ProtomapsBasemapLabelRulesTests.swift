// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The built-in style's label rules, read through the same `makeStyle` the
/// parser calls: every named point the tile ships becomes a label, and
/// how the labels rank decides which of them the collisions keep.
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
    /// basemap ships it at and at every deeper zoom. Every other label
    /// stands on the screen.
    func testAWaterNameIsPaintedOnTheMap() throws {
        let lake = style.makeStyle(data: feature(layer: "water", ["kind": .string("lake"), "name": .string("Lake"),
                                                                  "min_zoom": .int(6)], tileZoom: 8))
        guard case .pointLabel(let label) = lake, case .surface(let placement) = label.placement else {
            return XCTFail("a lake's name is a label painted on the map")
        }
        XCTAssertEqual(placement.referenceZoom, 6.5)
        XCTAssertFalse(placement.isVisible(atZoom: 5.9), "not before the zoom the basemap ships it at")
        XCTAssertTrue(placement.isVisible(atZoom: 6))
        XCTAssertTrue(placement.isVisible(atZoom: 8))
        XCTAssertTrue(placement.isVisible(atZoom: 16), "still on the water at street zoom")
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

    // MARK: Every label the tile ships

    func testEveryPlaceTheTileShipsIsLabelledAtEveryZoom() {
        for tileZoom in [0, 2, 3, 4, 8, 12] {
            XCTAssertTrue(isLabel(place(kind: "country", kindDetail: "country", tileZoom: tileZoom)), "z\(tileZoom)")
            XCTAssertTrue(isLabel(place(kind: "locality", kindDetail: "city", populationRank: 17, tileZoom: tileZoom)))
            XCTAssertTrue(isLabel(place(kind: "region", kindDetail: "state", tileZoom: tileZoom)), "z\(tileZoom)")
            XCTAssertTrue(isLabel(place(kind: "locality", kindDetail: "town", extra: ["min_zoom": .int(7)],
                                        tileZoom: tileZoom)), "z\(tileZoom)")
            XCTAssertTrue(isLabel(place(kind: "neighbourhood", kindDetail: "neighbourhood", tileZoom: tileZoom)),
                          "z\(tileZoom)")
        }
    }

    func testEveryWaterNameTheTileShipsIsLabelled() {
        for tileZoom in [0, 3, 4, 5, 12] {
            XCTAssertTrue(isLabel(feature(layer: "water", ["kind": .string("ocean"), "name": .string("Sea")],
                                          tileZoom: tileZoom)), "z\(tileZoom)")
            XCTAssertTrue(isLabel(feature(layer: "water", ["kind": .string("lake"), "name": .string("Lake")],
                                          tileZoom: tileZoom)), "z\(tileZoom)")
        }
    }

    // MARK: POIs

    func testEveryPoiKindBecomesALabel() {
        for kind in ["bicycle_parking", "waste_basket", "gate", "entrance", "bench", "bus_stop", "parking", "office"] {
            XCTAssertTrue(isLabel(poi(kind: kind, minZoom: 13)), "Kind \(kind) is labelled")
        }
    }

    func testAPoiWaitsForItsStatedZoom() {
        let restaurant = style.makeStyle(data: poi(kind: "restaurant", minZoom: 15, tileZoom: 14))
        XCTAssertNotNil(restaurant.labelTextStyle)
        XCTAssertEqual(restaurant.labelMinCameraZoom, 15, "the basemap's rank is the zoom it shows from")
        for tileZoom in [8, 12, 13] {
            XCTAssertTrue(isLabel(poi(kind: "restaurant", minZoom: 12, tileZoom: tileZoom)), "z\(tileZoom)")
            XCTAssertTrue(isLabel(poi(kind: "peak", minZoom: 7, tileZoom: tileZoom)), "z\(tileZoom)")
        }
    }

    func testAPoiWithoutAStatedZoomShowsWithItsTile() {
        XCTAssertEqual(style.makeStyle(data: poi(kind: "restaurant", minZoom: nil)).labelMinCameraZoom, 0)
    }

    // MARK: House numbers

    func testAnAddressPointIsLabelledWithItsHouseNumber() {
        let number = feature(layer: "buildings", ["kind": .string("address"), "addr_housenumber": .string("7/2")],
                             tileZoom: 15)
        XCTAssertEqual(number.facts.label?.name, "7/2")
        XCTAssertTrue(isLabel(number))
        XCTAssertFalse(isLabel(feature(layer: "buildings", ["kind": .string("address")], tileZoom: 15)))
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
