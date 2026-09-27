// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The route signs: which routes the built-in theme signs and on what, which
/// roads carry them, and where a tile stands them.
final class RouteShieldTests: XCTestCase {
    private let signs = ProtomapsBasemapTheme.RouteShields()

    // MARK: Theme rules

    func testANationalNumberLeadsTheEuropeanOne() {
        let shields = signs.shields(for: [ImmersiveMapRouteFacts(network: "e-road", text: "E22"),
                                          ImmersiveMapRouteFacts(network: "ru:national", text: "М-9")])
        XCTAssertEqual(shields.map(\.text), ["М-9", "E22"])
        XCTAssertEqual(shields.map(\.appearance.fillColor.x), [0.827, 0.0], "red for Russia, green for the E-road")
    }

    func testTheUnsignedNetworksAndTheLimitLeaveTheRightSigns() {
        // The M-4 south of Moscow carries four routes.
        let shields = signs.shields(for: [ImmersiveMapRouteFacts(network: "AsianHighway", text: "AH8"),
                                          ImmersiveMapRouteFacts(network: "e-road", text: "E115"),
                                          ImmersiveMapRouteFacts(network: "e-road", text: "E119"),
                                          ImmersiveMapRouteFacts(network: "ru:national", text: "М-4")])
        XCTAssertEqual(shields.map(\.text), ["М-4", "E115"],
                       "the Asian Highway is not signed, and a road carries at most two signs")
    }

    func testTheUnitedStatesSignsItsInterstatesHighwaysAndStateRoutesOnly() {
        let shields = signs.shields(for: [ImmersiveMapRouteFacts(network: "US:NJ:CR", text: "527"),
                                          ImmersiveMapRouteFacts(network: "US:I:Truck", text: "5"),
                                          ImmersiveMapRouteFacts(network: "US:NJ", text: "33"),
                                          ImmersiveMapRouteFacts(network: "US:I", text: "95")])
        XCTAssertEqual(shields.map(\.text), ["95", "33"])
        XCTAssertEqual(shields.map(\.appearance.shape), [.escutcheon, .capsule])
        XCTAssertNotNil(shields.first?.appearance.headerColor, "the Interstate sign wears its red crown")
    }

    func testANetworkPatternMatchesWithoutRegardToCaseAndBySegment() {
        let rule = ProtomapsBasemapTheme.RouteShields.Rule(network: "FR:*:D-road", appearance: nil)
        XCTAssertTrue(rule.matches("FR:94:D-road"))
        XCTAssertTrue(rule.matches("fr:92:d-road"))
        XCTAssertFalse(rule.matches("FR:D-road"))
        XCTAssertFalse(rule.matches("FR:94:D-road:extra"))
        let open = ProtomapsBasemapTheme.RouteShields.Rule(network: "US:*", appearance: nil)
        XCTAssertTrue(open.matches("US:CA"))
        XCTAssertTrue(open.matches("US:NJ:CR"), "a trailing star stands for one or more segments")
        XCTAssertFalse(open.matches("US"))
    }

    func testARouteNoRuleNamesTakesTheFallbackPlateAndTheSameNumberStandsOnce() {
        let shields = signs.shields(for: [ImmersiveMapRouteFacts(text: "46К-1011"),
                                          ImmersiveMapRouteFacts(network: "ru:regional", text: "46К-1011")])
        XCTAssertEqual(shields.map(\.text), ["46К-1011"])
        XCTAssertEqual(shields.first?.appearance, ProtomapsBasemapTheme.RouteShields.defaultFallback)
        var unsigned = signs
        unsigned.fallback = nil
        XCTAssertTrue(unsigned.shields(for: [ImmersiveMapRouteFacts(text: "46К-1011")]).isEmpty)
    }

    func testAChangedSignChangesTheCacheFingerprint() {
        let base = ProtomapsBasemapTheme.default
        let resized = base.routeShields { $0.sizePoints += 1 }
        let recoloured = base.routeShields { $0.rules[0].appearance?.fillColor = SIMD3<Float>(0, 0, 1) }
        XCTAssertNotEqual(base.cacheFingerprint, resized.cacheFingerprint)
        XCTAssertNotEqual(base.cacheFingerprint, recoloured.cacheFingerprint)
    }

    // MARK: Style

    func testAMotorwayCarriesItsSignsAndARampCarriesNone() {
        let motorway = roadStyle(["kind": .string("highway"), "kind_detail": .string("motorway"),
                                  "network_1": .string("ru:national"), "shield_text_1": .string("М-9")],
                                 tileZoom: 8)
        XCTAssertEqual(motorway?.shields?.shields.map(\.text), ["М-9"])
        XCTAssertNil(motorway?.label, "a road known only by its number lays no text along itself")

        let ramp = roadStyle(["kind": .string("highway"), "kind_detail": .string("motorway_link"),
                              "is_link": .bool(true),
                              "network_1": .string("ru:national"), "shield_text_1": .string("М-9")],
                             tileZoom: 12)
        XCTAssertNil(ramp?.shields)
    }

    func testALesserRoadWaitsForItsZoom() {
        let properties: [String: MvtValue] = ["kind": .string("major_road"), "kind_detail": .string("secondary"),
                                              "network_1": .string("ru:regional"), "shield_text_1": .string("46К-1300")]
        XCTAssertNil(roadStyle(properties, tileZoom: 10)?.shields)
        XCTAssertEqual(roadStyle(properties, tileZoom: 11)?.shields?.shields.map(\.text), ["46К-1300"])
    }

    // MARK: Placement

    func testTheTwoCarriagewaysOfAMotorwayStandOneSetOfSigns() {
        // Two parallel lines 40 units apart across the whole tile, as the
        // two directions of a motorway ship.
        let north = RouteShieldPlacement.candidatePoints(along: [SIMD2<Float>(0, 2028), SIMD2<Float>(4096, 2028)],
                                                         tileExtent: 4096)
        let south = RouteShieldPlacement.candidatePoints(along: [SIMD2<Float>(0, 2068), SIMD2<Float>(4096, 2068)],
                                                         tileExtent: 4096)
        XCTAssertEqual(north.count, 16, "a candidate every sixteenth of the tile")
        let style = RouteShieldStyle(shields: [], spacingPoints: 220)
        let candidates = (north + south).map { point in
            RouteShieldCandidate(shields: [], style: style, styleKey: 0, position: point, group: "М-9")
        }
        let kept = RouteShieldPlacement.select(candidates, tileExtent: 4096)
        XCTAssertEqual(kept.count, 1, "220 points is most of a 256-point tile")
        XCTAssertEqual(Double(kept[0].position.x), 1920, accuracy: 1, "the candidate nearest the centre")
    }

    func testDifferentSignsAreSpacedApart() {
        let style = RouteShieldStyle(shields: [], spacingPoints: 220)
        let candidates = [
            RouteShieldCandidate(shields: [], style: style, styleKey: 0, position: SIMD2<Float>(2000, 2000), group: "М-9"),
            RouteShieldCandidate(shields: [], style: style, styleKey: 0, position: SIMD2<Float>(2100, 2000), group: "А-107")
        ]
        XCTAssertEqual(RouteShieldPlacement.select(candidates, tileExtent: 4096).map(\.group), ["М-9", "А-107"],
                       "the spacing holds within one group of signs, the collisions settle the rest")
    }

    private func roadStyle(_ properties: [String: MvtValue], tileZoom: Int) -> RoadStyle? {
        ProtomapsBasemapDefaultMapStyle()
            .makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                 properties: properties,
                                                 tile: Tile(x: 0, y: 0, z: tileZoom),
                                                 geometryType: .linestring))
            .roadStyle
    }
}
