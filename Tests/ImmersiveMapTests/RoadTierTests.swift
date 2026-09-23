// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// A parser-level contract of the road network at street zoom: the
/// automobile roads draw as their own tier above the pedestrian one.
final class RoadTierTests: XCTestCase {
    // MARK: - Tiers

    func testAutomobileGroundDrawsAboveThePedestrianGround() {
        let order = RoadStructureKind.drawOrder
        let ground = order.firstIndex(of: .ground)!
        let automobile = order.firstIndex(of: .automobileGround)!
        let bridge = order.firstIndex(of: .bridge)!
        XCTAssertLessThan(ground, automobile, "Paths and rail first, then the automobile network over them")
        XCTAssertLessThan(automobile, bridge, "and bridges over both")
        XCTAssertEqual(order.first, .tunnel)
        // The arena image iterates the same order, slot by slot.
        XCTAssertEqual(Set(order), Set(RoadStructureKind.allCases))
    }

    func testTheTierLineSitsBetweenServiceRoadsAndPaths() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        func tier(_ className: String) -> RoadTier {
            style.makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                      properties: ProtomapsRoadSpelling.values(forClass: className),
                                                      tile: Tile(x: 19808, y: 10243, z: 15))).roadTier
        }
        for automobile in ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"] {
            XCTAssertEqual(tier(automobile), .automobile, "\(automobile) is automobile")
        }
        for pedestrian in ["path", "track"] {
            XCTAssertEqual(tier(pedestrian), .pedestrian, "\(pedestrian) is the finer network under it")
        }
        // Railways are skipped for now (see the style's routing): hidden,
        // so no road and no tier of their own.
        let rail = style.makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                             properties: ["kind": .string("rail"), "kind_detail": .string("rail")],
                                                             tile: Tile(x: 19808, y: 10243, z: 15)))
        XCTAssertNil(rail.roadStyle, "a railway draws nothing")
    }
}
