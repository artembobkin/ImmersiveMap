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
            var props: [String: MvtValue] = [:]
            let v = MvtValue.string(className); props["class"] = v
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

    /// What the tiles state is what gets painted.
    ///
    /// The schema carries `lanes` and `oneway` and nothing about paint, so a
    /// road without `lanes` has no marking evidence and stays bare: the class
    /// default the width falls back on is a guess about the ground, and the
    /// map used to paint a centre line down every unmarked back street from
    /// it. Classes below tertiary are bare whatever they carry.
    func testMarkingsComeFromTheTilesAndNotFromClassDefaults() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        let tile = Tile(x: 39616, y: 20486, z: 16)
        func markingPasses(_ attributes: [String: Any]) -> [LineRenderPass] {
            var properties: [String: MvtValue] = [:]
            for (key, value) in attributes {
                if let text = value as? String {
                    properties[key] = .string(text)
                } else if let number = value as? Int {
                    properties[key] = .int(Int64(number))
                } else {
                    properties[key] = .absent
                }
            }
            return style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: properties,
                                                             tile: tile))
                .resolvedLineRenderPasses
                .filter { $0.roadPassRole == .detail }
        }
        /// Painted lines, counted once each: every line is drawn by two
        /// passes, the dashed body and the solid approach to a junction.
        func markingLines(_ attributes: [String: Any]) -> Int {
            Set(markingPasses(attributes).map { $0.parseGeometryStyleData.lateralOffset }).count
        }

        XCTAssertEqual(markingLines(["class": "primary", "lanes": 2]), 1,
                       "A two-way avenue with a stated lane count carries its centre divider")
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 4]), 1,
                       "and only that: which of its lanes run each way is not in the tiles")
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 3]), 0,
                       "An odd lane count puts the centre inside a driving lane, so nothing is painted")
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 5]), 0)
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 4, "oneway": 1]), 3,
                       "A one-way carriageway carries a line on each boundary between its lanes")
        XCTAssertEqual(markingLines(["class": "primary"]), 0,
                       "Without a lane count there is no evidence of paint, so none is drawn")
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 1]), 0,
                       "A single-lane carriageway has nothing to divide")
        XCTAssertEqual(markingLines(["class": "minor", "lanes": 2]), 0,
                       "A residential street has no painted centre line")
        XCTAssertEqual(markingLines(["class": "minor", "lanes": 2, "oneway": 1]), 0,
                       "and a one-way one has no lane lines either")
        XCTAssertEqual(markingLines(["class": "service", "lanes": 2]), 0,
                       "nor does a service alley")
        XCTAssertEqual(markingLines(["class": "tertiary", "lanes": 2]), 1,
                       "The through hierarchy down to tertiary is painted")

        // Where the lane count came from decides whether it may be painted.
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 4, "lanes_src": "tagged"]), 1,
                       "A mapped lane count is evidence of paint")
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 4, "lanes_src": "assumed"]), 0,
                       "A lane count assumed from the class is a width, not a marking")

        // An unpaved road has no paint on it to draw.
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 4, "surface": "unpaved"]), 0,
                       "Gravel carries no lane lines")
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 4, "surface": "paved"]), 1,
                       "Asphalt does")
        XCTAssertEqual(markingLines(["class": "primary", "lanes": 4, "surface": "something_new"]), 1,
                       "A surface the tiles do not classify says nothing either way")
    }

    /// A street the tiles ship as one line through its junctions is cut for
    /// the marking pass at every interior point another carriageway touches,
    /// so the paint stops short of the crossing instead of running over it.
    func testMarkingsAreCutAtJunctions() {
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(200, 0), SIMD2(300, 0)]
        let fragment = ClippedLineFragment(points: line, startClipped: false, endClipped: false)
        // A side street ends at (200, 0): two drive-tier features touch it.
        let counts: [TileMvtParser.RoadConnectionPointKey: Int] = [
            .init(point: SIMD2(200, 0)): 2
        ]
        let pieces = TileMvtParser.splitAtJunctions(fragment: fragment, automobilePointCounts: counts)
        XCTAssertEqual(pieces.count, 2, "The line is cut at the junction")
        XCTAssertEqual(pieces[0].points, [SIMD2(0, 0), SIMD2(100, 0), SIMD2(200, 0)])
        XCTAssertEqual(pieces[1].points, [SIMD2(200, 0), SIMD2(300, 0)])
        XCTAssertFalse(pieces[0].endClipped, "The cut is a genuine end, so the inset applies to it")
        XCTAssertFalse(pieces[1].startClipped, "and to the piece that starts there")

        // A point only this street touches is not a junction.
        let untouched = TileMvtParser.splitAtJunctions(fragment: fragment, automobilePointCounts: [:])
        XCTAssertEqual(untouched.count, 1, "A plain interior vertex is not a junction")
        XCTAssertEqual(untouched[0].points, line)
    }

    func testMarkingsStateAHalfCarriagewayInset() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        var props: [String: MvtValue] = [:]
        let c = MvtValue.string("primary"); props["class"] = c
        let l = MvtValue.int(6); props["lanes"] = l
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
