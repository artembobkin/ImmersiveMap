// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

/// Pins the stitching rule of the road-network tile contract:
/// pieces of one street (same name and drawing attributes) that meet at an
/// endpoint no third road shares become one polyline before tessellation;
/// junctions, different streets, different classes and nameless pieces do not.
final class RoadStreetStitcherTests: XCTestCase {
    private let style = ProtomapsBasemapDefaultMapStyle(theme: .default)

    private func value(_ string: String) -> MvtValue {
        .string(string)
    }
    private func value(_ int: Int) -> MvtValue {
        .int(Int64(int))
    }

    private func attributes(name: String?, cls: String = "primary", link: Bool = false) -> [String: MvtValue] {
        var a = ProtomapsRoadSpelling.values(forClass: cls)
        if link { a["is_link"] = .bool(true) }
        if let name { a["name"] = value(name) }
        return a
    }

    private func styles(for attributes: [[String: MvtValue]]) -> [FeatureStyle] {
        attributes.map {
            style.makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                      properties: $0,
                                                      tile: Tile(x: 19807, y: 10243, z: 15)))
        }
    }

    private func facts(for attributes: [[String: MvtValue]]) -> [ImmersiveMapFeatureFacts] {
        attributes.map {
            ProtomapsBasemapSchema().facts(layerName: "roads",
                                            properties: $0,
                                            tile: Tile(x: 19807, y: 10243, z: 15))
        }
    }

    func testTwoPiecesOfOneStreetBecomeOnePolyline() {
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(500, 100), SIMD2(1000, 120)]],
            [[SIMD2(1000, 120), SIMD2(1500, 150), SIMD2(2000, 150)]],
        ]
        let attrs = [attributes(name: "Tverskaya"), attributes(name: "Tverskaya")]
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: attrs), featureStyles: styles(for: attrs))
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
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: attrs), featureStyles: styles(for: attrs))
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
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: attrs), featureStyles: styles(for: attrs))
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
        let attrs = [attributes(name: "A"), attributes(name: "A"), attributes(name: "B", cls: "minor")]
        let out = RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: attrs), featureStyles: styles(for: attrs))
        XCTAssertEqual(out, lines, "Three drive-tier features at one point is a junction; nothing is stitched")
    }

    func testDifferentStreetsAndDifferentClassesStayApart() {
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let otherStreet = [attributes(name: "A"), attributes(name: "B")]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: otherStreet), featureStyles: styles(for: otherStreet)), lines)
        let otherClass = [attributes(name: "A", cls: "primary"), attributes(name: "A", cls: "secondary")]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: otherClass), featureStyles: styles(for: otherClass)), lines,
                       "A class step is a real edge, not a seam to hide")
    }

    func testPiecesWithoutANameAreLeftAlone() {
        // Today's tiles: no name on the geometry layer. Nothing changes.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let attrs = [attributes(name: nil), attributes(name: nil)]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: attrs), featureStyles: styles(for: attrs)), lines)
    }

    func testPedestrianPiecesAreNotStitched() {
        // Only the automobile network stitches: a footway does not need it
        // and must not be welded to a street that shares its name.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let attrs = [attributes(name: "Alley", cls: "path"), attributes(name: "Alley", cls: "path")]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines, featureFacts: facts(for: attrs), featureStyles: styles(for: attrs)), lines)
    }

    func testOneStreetIsStillNotOneRibbonAcrossATunnelOrABridge() {
        // A street runs into a tunnel and out again: one street, but the
        // two pieces do not draw alike. Welding them
        // would draw the surface half as tunnel or the other way round.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        var attrs = [attributes(name: "Novy Arbat"), attributes(name: "Novy Arbat")]
        attrs[1]["is_tunnel"] = .bool(true)
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureFacts: facts(for: attrs), featureStyles: styles(for: attrs)),
                       lines,
                       "The tunnel keeps its own ribbon")

        // Same street, same everything that draws: one ribbon.
        var joined = attrs
        joined[1].removeValue(forKey: "is_tunnel")
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureFacts: facts(for: joined), featureStyles: styles(for: joined))[0],
                       [[SIMD2(0, 100), SIMD2(1000, 100), SIMD2(2000, 100)]])
    }

    func testARampIsARealEdgeEvenWithinOneStreet() {
        // The street's ramp carries the street's name: it draws one step
        // under its parent, so the pieces stay separate ribbons. Welding
        // them would draw the ramp at the parent's priority.
        let lines: [[[SIMD2<Float>]]] = [
            [[SIMD2(0, 100), SIMD2(1000, 100)]],
            [[SIMD2(1000, 100), SIMD2(2000, 100)]],
        ]
        let attrs = [attributes(name: "Mokhovaya"), attributes(name: "Mokhovaya", link: true)]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureFacts: facts(for: attrs), featureStyles: styles(for: attrs)),
                       lines,
                       "A street and its ramp are two ribbons")

        let same = [attributes(name: "Mokhovaya"), attributes(name: "Mokhovaya")]
        XCTAssertEqual(RoadStreetStitcher.stitch(linesByFeatureIndex: lines,
                                                 featureFacts: facts(for: same), featureStyles: styles(for: same))[0],
                       [[SIMD2(0, 100), SIMD2(1000, 100), SIMD2(2000, 100)]],
                       "Equal pieces weld as before")
    }
}
