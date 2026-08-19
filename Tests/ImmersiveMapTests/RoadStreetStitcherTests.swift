// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Pins the stitching rule of the road-network tile contract:
/// pieces of one street (same name and drawing attributes) that meet at an
/// endpoint no third road shares become one polyline before tessellation;
/// junctions, different streets, different widths and nameless pieces do not.
final class RoadStreetStitcherTests: XCTestCase {
    private let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

    private func value(_ string: String) -> VectorTile_Tile.Value {
        var v = VectorTile_Tile.Value(); v.stringValue = string; return v
    }
    private func value(_ int: Int) -> VectorTile_Tile.Value {
        var v = VectorTile_Tile.Value(); v.intValue = Int64(int); return v
    }

    private func attributes(name: String?, cls: String = "primary", lanes: Int = 4) -> [String: VectorTile_Tile.Value] {
        var a: [String: VectorTile_Tile.Value] = ["class": value(cls), "lanes": value(lanes)]
        if let name { a["name"] = value(name) }
        return a
    }

    private func styles(for attributes: [[String: VectorTile_Tile.Value]]) -> [FeatureStyle] {
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

    // MARK: - oneway

    func testOneWayCarriagewaysCarryLaneLinesNotACentreDivider() {
        func markings(oneway: VectorTile_Tile.Value?, lanes: Int) -> [LineRenderPass] {
            var a = attributes(name: "X", lanes: lanes)
            if let oneway { a["oneway"] = oneway }
            return styles(for: [a])[0].resolvedLineRenderPasses.filter { $0.roadPassRole == .detail }
        }
        // Two-way: one divider, on the centreline.
        let twoWay = markings(oneway: nil, lanes: 3)
        XCTAssertEqual(twoWay.count, 1, "No tag: two-way, one centre divider")
        XCTAssertEqual(twoWay[0].parseGeometryStyleData.lateralOffset, 0, "on the centreline")
        XCTAssertEqual(markings(oneway: value(0), lanes: 3).count, 1)

        // One-way with lanes: a line on each boundary between lanes, none on
        // the centreline (there is no centre to divide), symmetric about it.
        for oneway in [value(1), value(-1), value("yes")] {
            let lines = markings(oneway: oneway, lanes: 3)
            XCTAssertEqual(lines.count, 2, "three lanes, two boundaries")
            let offsets = lines.map { $0.parseGeometryStyleData.lateralOffset }.sorted()
            XCTAssertFalse(offsets.contains(0), "no centre divider on a one-way")
            XCTAssertEqual(offsets[0], -offsets[1], accuracy: 0.001, "the boundaries mirror about the centreline")
        }
        // A single-lane one-way is bare asphalt.
        XCTAssertTrue(markings(oneway: value(1), lanes: 1).isEmpty)
    }
}
