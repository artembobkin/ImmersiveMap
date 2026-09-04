// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

/// Pins the stitching rule of the road-network tile contract:
/// pieces of one street (same name and drawing attributes) that meet at an
/// endpoint no third road shares become one polyline before tessellation;
/// junctions, different streets, different widths and nameless pieces do not.
final class RoadStreetStitcherTests: XCTestCase {
    private let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

    private func value(_ string: String) -> MvtValue {
        .string(string)
    }
    private func value(_ int: Int) -> MvtValue {
        .int(Int64(int))
    }

    private func attributes(name: String?, cls: String = "primary", lanes: Int = 4) -> [String: MvtValue] {
        var a: [String: MvtValue] = ["class": value(cls), "lanes": value(lanes)]
        if let name { a["name"] = value(name) }
        return a
    }

    private func styles(for attributes: [[String: MvtValue]]) -> [FeatureStyle] {
        attributes.map {
            style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                      properties: $0,
                                                      tile: Tile(x: 39615, y: 20486, z: 16)))
        }
    }

    func testTwoPiecesOfOneStreetBecomeOnePolyline() {
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(500, 100), SIMD2(1000, 120)]],
            [[SIMD2(1000, 120), SIMD2(1500, 150), SIMD2(2000, 150)]],
        ]
        let attrs = [attributes(name: "Tverskaya"), attributes(name: "Tverskaya")]
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: attrs, featureStyles: styles(for: attrs))
        XCTAssertEqual(out[0], [[SIMD2(0, 100), SIMD2(500, 100), SIMD2(1000, 120), SIMD2(1500, 150), SIMD2(2000, 150)]],
                       "The first piece carries the whole street, with the shared point once")
        XCTAssertEqual(out[1], [], "The second piece is consumed")
    }

    func testAReversedPieceIsFlippedIntoTheChain() {
        // The second piece runs toward the join, so its end meets the first's end.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(2000, 100), SIMD2(1000, 100)]],
        ]
        let attrs = [attributes(name: "Mokhovaya"), attributes(name: "Mokhovaya")]
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: attrs, featureStyles: styles(for: attrs))
        XCTAssertEqual(out[0], [[SIMD2(0, 100), SIMD2(1000, 100), SIMD2(2000, 100)]])
        XCTAssertEqual(out[1], [])
    }

    func testAChainGrowsBackwardToo() {
        // The piece listed first is the middle one.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(1000, 0), SIMD2(2000, 0)]],
            [[SIMD2(0, 0), SIMD2(1000, 0)]],
            [[SIMD2(2000, 0), SIMD2(3000, 0)]],
        ]
        let attrs = Array(repeating: attributes(name: "Okhotny Ryad"), count: 3)
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: attrs, featureStyles: styles(for: attrs))
        XCTAssertEqual(out[0], [[SIMD2(0, 0), SIMD2(1000, 0), SIMD2(2000, 0), SIMD2(3000, 0)]])
        XCTAssertEqual(out[1], [])
        XCTAssertEqual(out[2], [])
    }

    func testAJunctionIsNeverStitchedAcross() {
        // Two pieces of one street meet at a node where a third road also
        // ends: a T. Gluing them would weld the street's two halves into one
        // ribbon that passes through the junction point without the junction
        // knowing, and the third road's end would cap against nothing.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
            [[SIMD2(1000, 100), SIMD2(1000, 800)]],
        ]
        let attrs = [attributes(name: "A"), attributes(name: "A"), attributes(name: "B", cls: "minor", lanes: 2)]
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: attrs, featureStyles: styles(for: attrs))
        XCTAssertEqual(out, lines, "Three drive-tier features at one point is a junction; nothing is stitched")
    }

    func testDifferentStreetsAndDifferentWidthsStayApart() {
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let otherStreet = [attributes(name: "A"), attributes(name: "B")]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: otherStreet,
                                                 featureStyles: styles(for: otherStreet)), lines)
        let otherWidth = [attributes(name: "A", lanes: 4), attributes(name: "A", lanes: 6)]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: otherWidth,
                                                 featureStyles: styles(for: otherWidth)), lines,
                       "A width step is a real edge, not a seam to hide")
    }

    func testPiecesWithoutANameAreLeftAlone() {
        // Today's tiles: no name on the geometry layer. Nothing changes.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let attrs = [attributes(name: nil), attributes(name: nil)]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: attrs,
                                                 featureStyles: styles(for: attrs)), lines)
    }

    func testPedestrianPiecesAreNotStitched() {
        // Only the automobile network stitches: a footway does not need it
        // and must not be welded to a street that shares its name.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let attrs = [attributes(name: "Alley", cls: "path"), attributes(name: "Alley", cls: "path")]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureAttributes: attrs,
                                                 featureStyles: styles(for: attrs)), lines)
    }

    // MARK: - the source's own street identity

    func testPiecesOfOneStreetJoinOnTheSourcesIdentityEvenWhereTheirAttributesDiffer() {
        // A tiler that assembles streets before cutting tiles states which
        // street a piece belongs to. Where it does, that answer replaces the
        // guess: these two pieces differ in lane count, which the attribute
        // comparison treats as two different streets, and they are one.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        var withStreet = [attributes(name: "Mokhovaya", lanes: 6), attributes(name: "Mokhovaya", lanes: 2)]
        withStreet[0]["street"] = value(4211)
        withStreet[1]["street"] = value(4211)
        let joined = RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                               featureAttributes: withStreet,
                                               featureStyles: styles(for: withStreet))
        XCTAssertEqual(joined[0], [[SIMD2(0, 100), SIMD2(1000, 100), SIMD2(2000, 100)]],
                       "One street on the ground, one ribbon on the map")
        XCTAssertEqual(joined[1], [])

        // Two different ids at the same point stay apart, whatever they are
        // called: this is a junction, not a seam.
        var different = withStreet
        different[1]["street"] = value(9002)
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureAttributes: different,
                                                 featureStyles: styles(for: different)),
                       lines)
    }

    func testOneStreetIsStillNotOneRibbonAcrossATunnelOrABridge() {
        // A street runs into a tunnel and out again: one street, and the
        // source says so, but the two pieces do not draw alike. Welding them
        // would draw the surface half as tunnel or the other way round.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        var attrs = [attributes(name: "Novy Arbat"), attributes(name: "Novy Arbat")]
        attrs[0]["street"] = value(5150)
        attrs[1]["street"] = value(5150)
        attrs[1]["brunnel"] = value("tunnel")
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureAttributes: attrs,
                                                 featureStyles: styles(for: attrs)),
                       lines,
                       "The tunnel keeps its own ribbon")

        // Same street, same everything that draws: one ribbon.
        var joined = attrs
        joined[1]["brunnel"] = value("")
        joined[1].removeValue(forKey: "brunnel")
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureAttributes: joined,
                                                 featureStyles: styles(for: joined))[0],
                       [[SIMD2(0, 100), SIMD2(1000, 100), SIMD2(2000, 100)]])
    }

    func testAStatedWidthChangeIsARealEdgeEvenWithinOneStreet() {
        // The street widens into a turn pocket before a junction: the stated
        // width differs, so the pieces stay separate ribbons. Welding them
        // would draw the whole street at one piece's width.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        var attrs = [attributes(name: "Mokhovaya", lanes: 5), attributes(name: "Mokhovaya", lanes: 5)]
        attrs[0]["street"] = value(4211); attrs[1]["street"] = value(4211)
        attrs[0]["width"] = value(120); attrs[1]["width"] = value(180)
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureAttributes: attrs,
                                                 featureStyles: styles(for: attrs)),
                       lines,
                       "Twelve metres and eighteen metres are two ribbons")

        var same = attrs
        same[1]["width"] = value(120)
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureAttributes: same,
                                                 featureStyles: styles(for: same))[0],
                       [[SIMD2(0, 100), SIMD2(1000, 100), SIMD2(2000, 100)]],
                       "Equal widths weld as before")
    }

    func testAPieceWithoutTheSourcesIdentityFallsBackToItsAttributes() {
        // A source that ships no street id is read as before.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let attrs = [attributes(name: "Tverskaya"), attributes(name: "Tverskaya")]
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                            featureAttributes: attrs,
                                            featureStyles: styles(for: attrs))
        XCTAssertEqual(out[0], [[SIMD2(0, 100), SIMD2(1000, 100), SIMD2(2000, 100)]])
    }

    // MARK: - oneway

    func testOneWayCarriagewaysCarryLaneLinesNotACentreDivider() {
        /// Where the paint runs, one entry per line. Each line is two passes
        /// (the dashed body and the solid approach to a junction), so the
        /// offsets are what says how many lines there are.
        func markingOffsets(oneway: MvtValue?, lanes: Int) -> [Double] {
            var a = attributes(name: "X", lanes: lanes)
            if let oneway { a["oneway"] = oneway }
            let passes = styles(for: [a])[0].resolvedLineRenderPasses.filter { $0.roadPassRole == .detail }
            return Set(passes.map { $0.parseGeometryStyleData.lateralOffset }).sorted()
        }
        // Two-way: one divider, on the centreline, and only where the lanes
        // divide evenly. An odd count leaves the centre inside a lane.
        XCTAssertEqual(markingOffsets(oneway: nil, lanes: 4), markingOffsets(oneway: value(0), lanes: 4),
                       "An explicit oneway=0 is the same two-way street as no tag at all")
        XCTAssertEqual(markingOffsets(oneway: nil, lanes: 2), [0], "one divider, on the centreline")
        XCTAssertEqual(markingOffsets(oneway: nil, lanes: 4), [0], "and one on a four-lane street too")
        XCTAssertTrue(markingOffsets(oneway: nil, lanes: 3).isEmpty,
                      "An odd two-way street is bare: the split between directions is unknown")

        // One-way with lanes: a line on each boundary between lanes, none on
        // the centreline (there is no centre to divide), symmetric about it.
        for oneway in [value(1), value(-1), value("yes")] {
            let offsets = markingOffsets(oneway: oneway, lanes: 3)
            XCTAssertEqual(offsets.count, 2, "three lanes, two boundaries")
            XCTAssertFalse(offsets.contains(0), "no centre divider on a one-way")
            XCTAssertEqual(offsets[0], -offsets[1], accuracy: 0.001, "the boundaries mirror about the centreline")
        }
        // A single-lane one-way is bare asphalt.
        XCTAssertTrue(markingOffsets(oneway: value(1), lanes: 1).isEmpty)
    }
}
