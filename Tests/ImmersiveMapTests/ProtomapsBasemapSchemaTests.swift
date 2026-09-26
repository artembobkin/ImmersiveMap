// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The reading of the Protomaps basemap schema: what a feature is, before
/// any style says how it draws.
final class ProtomapsBasemapSchemaTests: XCTestCase {
    private let schema = ProtomapsBasemapSchema()
    private let tile = Tile(x: 19807, y: 10243, z: 15)

    func testARoadLineCarriesItsStructureLayerAndName() throws {
        let road = try XCTUnwrap(facts(layer: "roads",
                                       ["kind": .string("major_road"), "kind_detail": .string("primary"),
                                        "is_tunnel": .bool(true), "layer": .sint(-1), "name": .string("Mokhovaya")],
                                       geometry: .linestring).road)
        XCTAssertEqual(road.structure, .tunnel)
        XCTAssertEqual(road.layer, -1)
        XCTAssertEqual(road.name, "Mokhovaya")
        XCTAssertNotNil(road.stitchingKey, "A line carries the key it stitches on")
        XCTAssertNil(facts(layer: "roads", ["kind": .string("major_road")], geometry: .linestring).road?.stitchingKey,
                     "Without a name there is nothing to stitch on")
        let bridge = try XCTUnwrap(facts(layer: "roads", ["is_bridge": .bool(true)], geometry: .linestring).road)
        XCTAssertEqual(bridge.structure, .bridge)
        XCTAssertNil(facts(layer: "roads", ["kind": .string("major_road")], geometry: .polygon).road,
                     "A polygon under the road layer is no road")
    }

    func testANegativeLayerAloneIsNotATunnel() throws {
        // A street diving under a bridge ships `layer=-1` and no tunnel
        // flag: it is in full view from above. It still draws under its
        // neighbours, which is the built-in style's reading of the layer.
        let road = try XCTUnwrap(facts(layer: "roads", ["layer": .sint(-1)], geometry: .linestring).road)
        XCTAssertEqual(road.structure, .ground)
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.roadLevel(road), .tunnel)
        let ramp = try XCTUnwrap(facts(layer: "roads", ["layer": .sint(1)], geometry: .linestring).road)
        XCTAssertEqual(ramp.structure, .ground)
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.roadLevel(ramp), .bridge)
    }

    func testTheStitchingKeyReadsWhatChangesTheDrawingAndNotTheRef() throws {
        func key(_ extra: [String: MvtValue]) -> String? {
            var properties: [String: MvtValue] = ["kind": .string("major_road"), "kind_detail": .string("primary"),
                                                  "name": .string("Tverskaya")]
            properties.merge(extra) { _, new in new }
            return facts(layer: "roads", properties, geometry: .linestring).road?.stitchingKey
        }
        XCTAssertEqual(key(["ref": .string("M10")]), key(["ref": .string("A104")]),
                       "a route reference is not a drawing change")
        XCTAssertNotEqual(key(["is_link": .bool(true)]), key([:]), "a ramp draws apart from its parent")
        XCTAssertNotEqual(key(["is_bridge": .bool(true)]), key([:]))
        XCTAssertNotEqual(key(["oneway": .bool(true)]), key([:]))
    }

    func testARoadWithOnlyARouteNumberIsNamedAndLabelledByIt() throws {
        let road = try XCTUnwrap(facts(layer: "roads", ["kind": .string("highway"), "ref": .string("M10;E105")],
                                       geometry: .linestring).road)
        XCTAssertEqual(road.name, "M10 / E105")
        XCTAssertEqual(road.label?.name, "M10 / E105")
        XCTAssertNotNil(road.stitchingKey, "the number is the road's identity for stitching")
    }

    func testANamedRoadWithARouteNumberLeadsItsLabelWithTheNumber() throws {
        let road = try XCTUnwrap(facts(layer: "roads",
                                       ["kind": .string("major_road"), "ref": .string("A104"),
                                        "name": .string("Dmitrovskoye"), "name:en": .string("Dmitrov Highway")],
                                       geometry: .linestring).road)
        XCTAssertEqual(road.name, "Dmitrovskoye", "the name stays the street's identity")
        XCTAssertEqual(road.label?.name, "A104 · Dmitrovskoye")
        XCTAssertEqual(road.label?.namesByLanguage["en"], "A104 · Dmitrov Highway")
    }

    func testABuildingCarriesItsHeightsAndKind() {
        let building = facts(layer: "buildings",
                             ["kind": .string("building"), "height": .double(24), "min_height": .double(3)],
                             geometry: .polygon).building
        XCTAssertEqual(building?.heightMetres, 24)
        XCTAssertEqual(building?.baseHeightMetres, 3)
        XCTAssertEqual(building?.isPart, false)
        XCTAssertNil(building?.buildingIdentity, "the basemap names no building identity")
        XCTAssertEqual(facts(layer: "buildings", ["kind": .string("building_part")], geometry: .polygon).building?.isPart, true)
        XCTAssertEqual(facts(layer: "buildings", ["layer": .sint(-1)], geometry: .polygon).building?.isHidden, true,
                       "an underground structure is not raised")
        XCTAssertNil(facts(layer: "buildings", ["kind": .string("address"), "addr_housenumber": .string("12b")],
                           geometry: .point).building,
                     "an address point is neither raised nor labelled")
        XCTAssertNil(facts(layer: "buildings", [:], geometry: .polygon).road)
    }

    func testAWaterPointNamesAWaterBodyAndTheFillsAreNothing() {
        XCTAssertTrue(facts(layer: "water", ["kind": .string("ocean"), "name": .string("Atlantic Ocean")],
                            geometry: .point).label?.namesWaterBody == true)
        XCTAssertNil(facts(layer: "water", ["kind": .string("lake"), "name": .string("Baikal")], geometry: .polygon).label,
                     "the fill of a named lake is called nothing: its point carries the name")
        XCTAssertNil(facts(layer: "water", ["kind": .string("river"), "name": .string("Volga")], geometry: .linestring).label)
        for layer in ["landuse", "earth", "boundaries", "landcover", "transit"] {
            let fill = facts(layer: layer, ["kind": .string("residential"), "name": .string("Named")], geometry: .polygon)
            XCTAssertNil(fill.road, layer)
            XCTAssertNil(fill.building, layer)
            XCTAssertNil(fill.label, "\(layer) is called nothing, even with a name")
        }
    }

    func testNamesAreReadByLanguage() throws {
        let place = try XCTUnwrap(facts(layer: "places",
                                        ["name": .string("Москва"), "name:en": .string("Moscow"), "name:de": .string("Moskau"),
                                         "pgf:name:hi": .string("shaped"), "name2": .string("Moskva"),
                                         "script": .string("Cyrillic")],
                                        geometry: .point).label)
        XCTAssertEqual(place.name, "Москва")
        XCTAssertEqual(place.namesByLanguage, ["en": "Moscow", "de": "Moskau"])

        let poi = try XCTUnwrap(facts(layer: "pois", ["kind": .string("cafe"), "name": .string("Кафе")], geometry: .point).label)
        XCTAssertEqual(poi.name, "Кафе")
        XCTAssertNil(facts(layer: "pois", ["kind": .string("cafe")], geometry: .point).label, "an unnamed POI is nothing")

        let road = facts(layer: "roads", ["kind": .string("major_road"), "name": .string("Tverskaya")], geometry: .linestring)
        XCTAssertEqual(road.label?.name, "Tverskaya", "A road carries its name for the label along it")
        XCTAssertNotNil(road.road)
    }

    func testARegionalCodeIsAlsoFiledUnderItsLanguage() throws {
        let place = try XCTUnwrap(facts(layer: "places",
                                        ["name": .string("北京市"), "name:zh-Hans": .string("北京"), "name:zh-Hant": .string("北京")],
                                        geometry: .point).label)
        XCTAssertEqual(place.namesByLanguage["zh"], "北京", "the map's language asks by the code before the dash")
        XCTAssertEqual(place.namesByLanguage["zh-Hans"], "北京")
        let stated = try XCTUnwrap(facts(layer: "places",
                                         ["name:zh": .string("plain"), "name:zh-Hans": .string("simplified")],
                                         geometry: .point).label)
        XCTAssertEqual(stated.namesByLanguage["zh"], "plain", "a stated language entry is never overwritten")
    }

    private func facts(layer: String,
                       _ properties: [String: MvtValue],
                       geometry: MvtGeometryType) -> ImmersiveMapFeatureFacts {
        schema.facts(layerName: layer, properties: properties, tile: tile, geometryType: geometry)
    }
}
