// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The Protomaps basemap's reading of a building: the schema's answer to
/// what a polygon feature is as a building, which the parser never reads
/// itself.
final class ImmersiveMapBuildingExtrusionTests: XCTestCase {
    private func building(_ values: [String: MvtValue]) -> ImmersiveMapBuildingExtrusion {
        ProtomapsBasemapSchema().facts(layerName: "buildings",
                                       properties: values,
                                       tile: Tile(x: 0, y: 0, z: 15),
                                       geometryType: .polygon).building!
    }

    func testHeightsComeFromTheBasemapInMetres() {
        XCTAssertEqual(building(["height": .double(12)]).heightMetres, 12)
        XCTAssertEqual(building(["height": .string("30 ft")]).heightMetres, 30 * 0.3048)
        let podium = building(["height": .double(40), "min_height": .double(12)])
        XCTAssertEqual(podium.heightMetres, 40)
        XCTAssertEqual(podium.baseHeightMetres, 12)
        XCTAssertNil(building([:]).heightMetres, "the basemap states the height, or there is none")
    }

    func testPartAndHiddenFlagsReadTheTags() {
        let part = building(["kind": .string("building_part")])
        XCTAssertNil(part.buildingIdentity, "the basemap names no building identity")
        XCTAssertTrue(part.isPart)
        XCTAssertFalse(part.isHidden)
        XCTAssertFalse(building(["kind": .string("building")]).isPart)
        XCTAssertTrue(building(["layer": .sint(-1)]).isHidden, "an underground structure is not raised")
        XCTAssertFalse(building([:]).isHidden, "absent flags mean extruded")
    }
}
