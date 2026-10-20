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

    /// The bands: a city before a peak before a town before a lake before
    /// an airport before a restaurant, whatever their own ranks.
    func testCollisionRankOrdersTheLayersPlacesFirst() {
        let cityStyle = style.makeStyle(data: place(populationRank: 5, tileZoom: 10))
        let townStyle = style.makeStyle(data: place(kindDetail: "town", populationRank: 17, tileZoom: 10))
        let waterStyle = style.makeStyle(data: feature(layer: "water", ["kind": .string("lake"), "name": .string("Lake"),
                                                                        "min_zoom": .int(4)], tileZoom: 10))
        let peakStyle = style.makeStyle(data: poi(kind: "peak", minZoom: 9, tileZoom: 10))
        let airportStyle = style.makeStyle(data: poi(kind: "aerodrome", minZoom: 9, tileZoom: 10))
        let poiStyle = style.makeStyle(data: poi(kind: "restaurant", minZoom: 13))

        XCTAssertEqual(cityStyle.labelCollisionRank, cityStyle.labelRank, "a city collides at its own rank")
        XCTAssertLessThan(cityStyle.labelCollisionRank, peakStyle.labelCollisionRank)
        XCTAssertLessThan(peakStyle.labelCollisionRank, townStyle.labelCollisionRank,
                          "The Matterhorn's name over the villages on its slopes")
        XCTAssertLessThan(townStyle.labelCollisionRank, waterStyle.labelCollisionRank)
        XCTAssertLessThan(waterStyle.labelCollisionRank, airportStyle.labelCollisionRank)
        XCTAssertLessThan(airportStyle.labelCollisionRank, poiStyle.labelCollisionRank)
    }

    /// Which places keep their band ahead of the peaks: a country, a
    /// region, a city. A town, a village, a hamlet and a neighbourhood
    /// yield to a peak whatever their population rank.
    func testAPeakBeatsEveryPlaceUnderACity() {
        let peak = style.makeStyle(data: poi(kind: "peak", minZoom: 9, tileZoom: 10)).labelCollisionRank
        for (kind, detail) in [("locality", "town"), ("locality", "village"), ("locality", "hamlet"),
                               ("locality", "locality"), ("neighbourhood", "neighbourhood"), ("macrohood", "macrohood")] {
            let settlement = style.makeStyle(data: place(kind: kind, kindDetail: detail, populationRank: 17, tileZoom: 10))
            XCTAssertGreaterThan(settlement.labelCollisionRank, peak, "\(kind) \(detail)")
        }
        for (kind, detail) in [("country", "country"), ("region", "state"), ("locality", "city")] {
            let major = style.makeStyle(data: place(kind: kind, kindDetail: detail, populationRank: 0, tileZoom: 10))
            XCTAssertLessThan(major.labelCollisionRank, peak, "\(kind) \(detail)")
        }
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

    // MARK: The names of the lands

    /// A country's name is the name of a land, above every city's size, a
    /// capital's included, and set apart from them: spaced capitals in the
    /// thin face. A region's name is the same manner, under the country's
    /// and still above a city's.
    func testACountrysNameStandsAboveEveryCitys() throws {
        let country = try XCTUnwrap(style.makeStyle(data: place(kind: "country", kindDetail: "country", populationRank: 10)).labelTextStyle)
        let region = try XCTUnwrap(style.makeStyle(data: place(kind: "region", kindDetail: "state", populationRank: 10)).labelTextStyle)
        let capital = try XCTUnwrap(style.makeStyle(data: place(populationRank: 10, extra: ["capital": .string("yes")])).labelTextStyle)
        let city = try XCTUnwrap(style.makeStyle(data: place(populationRank: 10)).labelTextStyle)
        XCTAssertGreaterThan(country.sizePoints, capital.sizePoints)
        XCTAssertGreaterThan(capital.sizePoints, city.sizePoints)
        XCTAssertGreaterThanOrEqual(region.sizePoints, city.sizePoints,
                                    "A region's name is no smaller than a city's, and its spaced capitals read larger")
        XCTAssertLessThan(region.sizePoints, country.sizePoints, "and under its country's")
        for land in [country, region] {
            XCTAssertTrue(land.uppercased)
            XCTAssertGreaterThan(land.letterSpacingEm, 0, "Spaced out over the land it names")
            XCTAssertEqual(land.weight, .thin)
            XCTAssertLessThan(land.opacity, 1, "Lettering the land shows through")
            XCTAssertGreaterThan(land.opacity, 0.5)
        }
        XCTAssertFalse(city.uppercased)
        XCTAssertEqual(city.letterSpacingEm, 0)
        XCTAssertEqual(city.opacity, 1)
        XCTAssertEqual(capital.weight, .bold)
    }

    /// The name of a land goes away where the land no longer fits the
    /// view, at the theme's zoom, and a city's name never does.
    func testTheNameOfALandLeavesTheStreetZooms() throws {
        let country = try XCTUnwrap(style.makeStyle(data: place(kind: "country", kindDetail: "country")).pointLabelStyle)
        let region = try XCTUnwrap(style.makeStyle(data: place(kind: "region", kindDetail: "state")).pointLabelStyle)
        let city = try XCTUnwrap(style.makeStyle(data: place()).pointLabelStyle)
        XCTAssertEqual(country.maxCameraZoom, 8)
        XCTAssertEqual(region.maxCameraZoom, 10)
        XCTAssertEqual(city.maxCameraZoom, .infinity)

        let deeper = ProtomapsBasemapDefaultMapStyle(theme: .default.labelVisibility { visibility in
            visibility.countryMaximumZoom = 6
            visibility.regionMaximumZoom = 12
        })
        XCTAssertEqual(try XCTUnwrap(deeper.makeStyle(data: place(kind: "country", kindDetail: "country")).pointLabelStyle).maxCameraZoom, 6)
        XCTAssertEqual(try XCTUnwrap(deeper.makeStyle(data: place(kind: "region", kindDetail: "state")).pointLabelStyle).maxCameraZoom, 12)
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
