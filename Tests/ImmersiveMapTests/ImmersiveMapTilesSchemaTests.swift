// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The reading of the hosted tiles' schema: what a feature is, before any
/// style says how it draws.
final class ImmersiveMapTilesSchemaTests: XCTestCase {
    private let schema = ImmersiveMapTilesSchema()
    private let tile = Tile(x: 39615, y: 20486, z: 16)

    func testARoadLineIsACentrelineWithItsStructureLayerAndStreet() throws {
        let road = try XCTUnwrap(facts(layer: "transportation",
                                       ["class": .string("primary"), "brunnel": .string("tunnel"),
                                        "layer": .int(-1), "street": .string("4211"), "name": .string("Mokhovaya")],
                                       geometry: .linestring).road)
        XCTAssertEqual(road.kind, .centreline)
        XCTAssertEqual(road.structure, .tunnel)
        XCTAssertTrue(road.isTunnel)
        XCTAssertEqual(road.layer, -1)
        XCTAssertEqual(road.streetIdentity, "4211")
        XCTAssertNotNil(road.stitchingKey, "A line carries the key it stitches on")
        XCTAssertFalse(road.isSurface)
        XCTAssertFalse(road.isShippedPaint)
    }

    func testANegativeLayerAloneIsNotATunnel() throws {
        // A street diving under a bridge ships `layer=-1` and no tunnel
        // flag: it is in full view from above. It still draws under its
        // neighbours, which is the built-in style's reading of the layer.
        let road = try XCTUnwrap(facts(layer: "transportation", ["layer": .int(-1)], geometry: .linestring).road)
        XCTAssertEqual(road.structure, .ground)
        XCTAssertFalse(road.isTunnel)
        XCTAssertEqual(ImmersiveMapTilesDefaultMapStyle.roadLevel(road), .tunnel)
        let ramp = try XCTUnwrap(facts(layer: "transportation", ["layer": .int(1)], geometry: .linestring).road)
        XCTAssertEqual(ramp.structure, .ground)
        XCTAssertEqual(ImmersiveMapTilesDefaultMapStyle.roadLevel(ramp), .bridge)
    }

    func testTheSurfacesAndTheLotAreReadByTheirSubclass() throws {
        XCTAssertEqual(facts(layer: "transportation",
                             ["subclass": .string("junction_area"), "origin": .string("graph")],
                             geometry: .polygon).road?.kind,
                       .surface(reconstructed: true))
        XCTAssertEqual(facts(layer: "transportation",
                             ["subclass": .string("junction_area")],
                             geometry: .polygon).road?.kind,
                       .surface(reconstructed: false),
                       "A junction area without a graph origin was mapped by hand")
        XCTAssertEqual(facts(layer: "transportation",
                             ["subclass": .string("carriageway_area")],
                             geometry: .polygon).road?.kind,
                       .surface(reconstructed: true))
        XCTAssertEqual(facts(layer: "transportation",
                             ["subclass": .string("parking_area"), "orientation": .string("parallel")],
                             geometry: .polygon).road?.kind,
                       .parkingLot(baysParallel: true))
        let surface = try XCTUnwrap(facts(layer: "transportation",
                                          ["subclass": .string("carriageway_area"), "street": .string("7")],
                                          geometry: .polygon).road)
        XCTAssertNil(surface.stitchingKey, "A surface is never stitched")
        XCTAssertTrue(surface.isSurface)
    }

    func testMeasuredPaintIsPaintWhateverElseItCarries() {
        let paint = facts(layer: "streetscape",
                          ["marking": .string("dividing"), "subclass": .string("junction_area"),
                           "paint": .string("yellow"), "style": .string("solid")],
                          geometry: .linestring).road
        XCTAssertEqual(paint?.paint, ImmersiveMapRoadPaint(kind: .dividingLine, isYellow: true, isDashed: false))
        XCTAssertTrue(paint?.isShippedPaint == true)
    }

    func testTheKindsOfMeasuredPaint() {
        func kind(_ marking: String) -> ImmersiveMapRoadPaint.Kind? {
            facts(layer: "streetscape", ["marking": .string(marking)], geometry: .linestring).road?.paint?.kind
        }
        XCTAssertEqual(kind("crossing_marked"), .crossing(marked: true))
        XCTAssertEqual(kind("crossing_unmarked"), .crossing(marked: false))
        XCTAssertEqual(kind("lane_separator"), .laneSeparator)
        XCTAssertEqual(kind("edge"), .edgeLine)
        XCTAssertEqual(kind("bus_lane"), .busLane)
        XCTAssertEqual(kind("bus_stop_zigzag"), .busStopKerb)
        XCTAssertEqual(kind("stop_line"), .other("stop_line"))
        XCTAssertNil(facts(layer: "streetscape", ["marking": .string("dividing")], geometry: .linestring).road?.paint?.isDashed,
                     "The source did not say")
    }

    func testABuildingCarriesItsHeights() {
        let building = facts(layer: "building",
                             ["render_height": .double(24), "render_min_height": .double(3)],
                             geometry: .polygon).building
        XCTAssertEqual(building?.heightMetres, 24)
        XCTAssertEqual(building?.baseHeightMetres, 3)
        XCTAssertNil(facts(layer: "building", [:], geometry: .polygon).road)
    }

    func testAWaterNameNamesAWaterBodyAndTheRestIsNothing() {
        XCTAssertTrue(facts(layer: "water_name", ["class": .string("ocean")], geometry: .point).namesWaterBody)
        let landuse = facts(layer: "landuse", ["class": .string("residential")], geometry: .polygon)
        XCTAssertNil(landuse.road)
        XCTAssertNil(landuse.building)
        XCTAssertFalse(landuse.namesWaterBody)
    }

    private func facts(layer: String,
                       _ properties: [String: MvtValue],
                       geometry: MvtGeometryType) -> ImmersiveMapFeatureFacts {
        schema.facts(layerName: layer, properties: properties, tile: tile, geometryType: geometry)
    }
}
