// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Two parser-level contracts of the road network at street zoom: the
/// automobile roads draw as their own tier above the pedestrian one, and paint
/// on a road stops short of the road's ends and junctions while running flush
/// through a tile seam.
final class RoadTierAndMarkingInsetTests: XCTestCase {
    // MARK: - Tiers

    func testAutomobileGroundDrawsAboveThePedestrianGround() {
        let order = TileMvtParser.RoadStructureKind.drawOrder
        let ground = order.firstIndex(of: .ground)!
        let automobile = order.firstIndex(of: .automobileGround)!
        let bridge = order.firstIndex(of: .bridge)!
        XCTAssertLessThan(ground, automobile, "Paths and rail first, then the automobile network over them")
        XCTAssertLessThan(automobile, bridge, "and bridges over both")
        XCTAssertEqual(order.first, .tunnel)
        // The arena image iterates the same order, slot by slot.
        XCTAssertEqual(Set(order), Set(TileMvtParser.RoadStructureKind.allCases))
    }

    func testTheTierLineSitsBetweenServiceRoadsAndPaths() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func priority(_ className: String) -> Int {
            var props: [String: VectorTile_Tile.Value] = [:]
            var v = VectorTile_Tile.Value(); v.stringValue = className; props["class"] = v
            return style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: props,
                                                             tile: Tile(x: 39616, y: 20486, z: 16))).roadClassPriority
        }
        let floor = TileMvtParser.automobileRoadClassPriorityFloor
        for automobile in ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"] {
            XCTAssertGreaterThanOrEqual(priority(automobile), floor, "\(automobile) is automobile")
        }
        for pedestrian in ["path", "track", "rail"] {
            XCTAssertLessThan(priority(pedestrian), floor, "\(pedestrian) is the finer network under it")
        }
    }

    // MARK: - End inset

    func testInsetPullsBothEndsBackAlongThePath() throws {
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 100)]
        let inset = try XCTUnwrap(TileMvtParser.insetLineEnds(line, inset: 10, insetStart: true, insetEnd: true))
        XCTAssertEqual(inset.first, SIMD2<Float>(10, 0))
        XCTAssertEqual(inset.last, SIMD2<Float>(100, 90))
        XCTAssertEqual(inset.count, 3, "An inset shorter than the end segments keeps every corner")
    }

    func testInsetConsumesWholeSegmentsWhenLongerThanThem() throws {
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(5, 0), SIMD2(100, 0)]
        let inset = try XCTUnwrap(TileMvtParser.insetLineEnds(line, inset: 20, insetStart: true, insetEnd: false))
        XCTAssertEqual(inset.first, SIMD2<Float>(20, 0), "The 5-unit first segment is consumed and the inset continues into the next")
        XCTAssertEqual(inset.count, 2)
    }

    func testASeamEndKeepsItsPointSoTheLineContinuesFlush() throws {
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 0)]
        let inset = try XCTUnwrap(TileMvtParser.insetLineEnds(line, inset: 10, insetStart: false, insetEnd: true))
        XCTAssertEqual(inset.first, SIMD2<Float>(0, 0), "A tile-seam end is not an end: no inset")
        XCTAssertEqual(inset.last, SIMD2<Float>(90, 0))
    }

    func testAStubShorterThanItsInsetsIsNoPaint() {
        let stub: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(15, 0)]
        XCTAssertNil(TileMvtParser.insetLineEnds(stub, inset: 10, insetStart: true, insetEnd: true),
                     "Two 10-unit insets on a 15-unit stub leave nothing to paint")
        XCTAssertNotNil(TileMvtParser.insetLineEnds(stub, inset: 10, insetStart: true, insetEnd: false))
    }

    func testNoInsetIsIdentity() {
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 0)]
        XCTAssertEqual(TileMvtParser.insetLineEnds(line, inset: 0, insetStart: true, insetEnd: true), line)
    }

    func testMarkingsStateAHalfCarriagewayInset() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        var props: [String: VectorTile_Tile.Value] = [:]
        var c = VectorTile_Tile.Value(); c.stringValue = "primary"; props["class"] = c
        var l = VectorTile_Tile.Value(); l.intValue = 6; props["lanes"] = l
        let featureStyle = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                     properties: props,
                                                                     tile: Tile(x: 39616, y: 20486, z: 16)))
        let passes = featureStyle.resolvedLineRenderPasses
        let fill = try XCTUnwrap(passes.first { $0.roadPassRole == .fill })
        let marking = try XCTUnwrap(passes.first { $0.roadPassRole == .detail })
        XCTAssertEqual(marking.parseGeometryStyleData.endInset, fill.parseGeometryStyleData.lineWidth * 0.5,
                       accuracy: 0.001,
                       "Paint stops half a carriageway short of the road's ends and junctions")
        XCTAssertEqual(fill.parseGeometryStyleData.endInset, 0, "The carriageway itself runs to its ends")
    }
}
