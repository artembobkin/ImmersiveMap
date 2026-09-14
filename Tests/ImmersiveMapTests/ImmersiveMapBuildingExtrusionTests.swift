// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The hosted tiles' reading of a building: the schema's answer to what a
/// polygon feature is as a building, which the parser never reads itself.
final class ImmersiveMapBuildingExtrusionTests: XCTestCase {
    private func building(_ values: [String: MvtValue]) -> ImmersiveMapBuildingExtrusion {
        ImmersiveMapTilesSchema().facts(layerName: "building",
                                        properties: values,
                                        tile: Tile(x: 0, y: 0, z: 16),
                                        geometryType: .polygon).building!
    }

    private func roof(_ values: [String: MvtValue]) -> ImmersiveMapRoof? {
        building(values).roof
    }

    func testHeightsComeFromEitherSchemaOrFromLevels() {
        XCTAssertEqual(building((["height": .double(12)])).heightMetres, 12)
        XCTAssertEqual(building((["render_height": .string("30 ft")])).heightMetres,
                       30 * 0.3048)
        let levels = building((["building:levels": .int(4),
                                                                              "building:min_level": .int(1)]))
        XCTAssertEqual(levels.heightMetres, 4 * ImmersiveMapTilesSchema.metresPerBuildingLevel)
        XCTAssertEqual(levels.baseHeightMetres, 1 * ImmersiveMapTilesSchema.metresPerBuildingLevel)
        XCTAssertNil(building(([:])).heightMetres)
    }

    func testIdentityPartAndHiddenFlagsReadTheTags() {
        let part = building((["osm_id": .uint(42),
                                                                            "building:part": .string("yes")]))
        XCTAssertEqual(part.buildingIdentity, 42)
        XCTAssertTrue(part.isPart)
        XCTAssertFalse(part.isHidden)
        XCTAssertTrue(building((["extrude": .string("false")])).isHidden)
        XCTAssertTrue(building((["hide_3d": .bool(true)])).isHidden)
        XCTAssertTrue(building((["location": .string("underground")])).isHidden)
        XCTAssertFalse(building(([:])).isHidden,
                       "An absent extrude flag means extruded")
    }

    func testRoofParsesOrientationAndNumericDirection() throws {
        let roof = try XCTUnwrap(roof([
            "roof:shape": .string("gabled"),
            "roof:height": .double(4),
            "roof:orientation": .string("across"),
            "roof:direction": .double(135)
        ]))
        XCTAssertEqual(roof.shape, .gabled)
        XCTAssertEqual(roof.heightMetres, 4)
        XCTAssertEqual(roof.orientation, .across)
        XCTAssertEqual(try XCTUnwrap(roof.directionDegrees), 135, accuracy: 0.001)
    }

    func testRoofParsesCompassPointDirection() throws {
        let roof = try XCTUnwrap(roof([
            "roof:shape": .string("skillion"),
            "roof:height": .double(2),
            "roof:direction": .string("SE")
        ]))
        XCTAssertEqual(try XCTUnwrap(roof.directionDegrees), 135, accuracy: 0.001)
    }

    func testAbsentRoofTagsLeaveOrientationAndDirectionNil() throws {
        let roof = try XCTUnwrap(roof([
            "roof:shape": .string("hipped"),
            "roof:levels": .int(1)
        ]))
        XCTAssertEqual(roof.heightMetres, ImmersiveMapTilesSchema.metresPerRoofLevel)
        XCTAssertNil(roof.orientation)
        XCTAssertNil(roof.directionDegrees)
    }

    func testRoofMapsShapeAliasesOntoBuildableShapes() throws {
        let cases: [(String, ImmersiveMapRoofShape)] = [
            ("gambrel", .gabled),
            ("mansard", .hipped),
            ("half-dome", .dome),
            ("onion", .dome),
            ("pyramidal", .pyramid)
        ]
        for (raw, expected) in cases {
            let roof = try XCTUnwrap(roof([
                "roof:shape": .string(raw),
                "roof:height": .double(2)
            ]), "\(raw) should parse")
            XCTAssertEqual(roof.shape, expected, "\(raw)")
        }
        XCTAssertNil(roof(["roof:shape": .string("flat"), "roof:height": .double(2)]), "A flat roof is the lid")
        XCTAssertNil(roof(["roof:shape": .string("sawtooth"), "roof:height": .double(2)]), "An unknown shape is the lid")
        XCTAssertNil(roof(["roof:shape": .string("gabled")]), "A roof without height is the lid")
    }
}
