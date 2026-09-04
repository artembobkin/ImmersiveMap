// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// Paint the source measured on the ground ships as its own line features
/// (`marking` in `transportation`), and the style draws exactly the shipped
/// polyline: the kind decides stroke, colour and dash pattern, the pattern is
/// a length in metres so the dashes sit still on the asphalt, and the
/// `isShippedRoadPaint` flag keeps the road machinery off geometry that
/// already ends where the paint ends.
final class RoadShippedMarkingStyleTests: XCTestCase {
    private let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

    private func moscowTile(z: Int) -> Tile {
        z >= 16 ? Tile(x: 39615, y: 20486, z: 16)
                : Tile(x: 39615 >> (16 - z), y: 20486 >> (16 - z), z: z)
    }

    /// Ground metres one tile unit spans, derived independently of the style.
    private func metresPerUnit(_ tile: Tile) -> Double {
        let tilesCount = Double(1 << tile.z)
        let normalizedY = (Double(tile.y) + 0.5) / tilesCount
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * normalizedY)))
        return 40_075_016.686 * cos(latitude) / tilesCount / 4096.0
    }

    private func stringValue(_ value: String) -> MvtValue {
        .string(value)
    }

    private func markingStyle(_ kind: String, z: Int = 16,
                              extra: [String: String] = [:]) -> FeatureStyle {
        var props: [String: MvtValue] = ["marking": stringValue(kind)]
        for (key, value) in extra { props[key] = stringValue(value) }
        return style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                         properties: props,
                                                         tile: moscowTile(z: z)))
    }

    func testADividingLineIsADashedDetailStrokeWithAMetrePattern() {
        let dividing = markingStyle("dividing")
        XCTAssertTrue(dividing.isShippedRoadPaint, "Shipped paint carries the bypass flag")
        let pass = dividing.resolvedLineRenderPasses.first
        XCTAssertEqual(dividing.resolvedLineRenderPasses.count, 1, "One pass: the stroke itself")
        XCTAssertEqual(pass?.roadPassRole, .detail, "drawn above every carriageway fill")
        XCTAssertEqual(pass?.key, 60)
        XCTAssertEqual(pass?.parseGeometryStyleData.endInset ?? -1, 0,
                       "No junction inset: the line already ends where the paint ends")
        XCTAssertEqual(pass?.parseGeometryStyleData.lateralOffset ?? -1, 0,
                       "and no lateral offset: the polyline IS the paint")
        XCTAssertEqual(pass?.dashInTileUnits, true, "The pattern is world-locked")
        let metres = metresPerUnit(moscowTile(z: 16))
        XCTAssertEqual(Double(pass?.dashLengthPoints ?? 0) * metres, 2.0, accuracy: 0.05,
                       "Two metres of paint")
        XCTAssertEqual(Double(pass?.dashGapPoints ?? 0) * metres, 4.5, accuracy: 0.05,
                       "four and a half of gap")
    }

    func testYellowPaintIsItsOwnBakedStyle() {
        let white = markingStyle("dividing")
        let yellow = markingStyle("dividing", extra: ["paint": "yellow"])
        XCTAssertNotEqual(yellow.key, white.key,
                          "A key is a baked style, so a colour needs its own")
        XCTAssertNotEqual(yellow.color, white.color)
        XCTAssertGreaterThan(yellow.color.x, yellow.color.z,
                             "Yellow paint is warm: more red than blue")
    }

    func testMarkingPaintIsFullyOpaque() {
        // A translucent marking washed out against the surface, and every
        // overlap of two decoration quads (the letter's strokes, the
        // sawtooth's joints) composited its alpha twice into a denser
        // patch. Muting lives in the tone; the alpha is 1.
        XCTAssertEqual(markingStyle("dividing").color.w, 1.0, "White paint covers")
        XCTAssertEqual(markingStyle("dividing", extra: ["paint": "yellow"]).color.w, 1.0,
                       "and so does the yellow")
    }

    func testALaneSeparatorIsAOneMetreDashAndOnlyAtStreetZoom() {
        let separator = markingStyle("lane_separator")
        let pass = separator.resolvedLineRenderPasses.first
        XCTAssertEqual(pass?.key, 58)
        let metres = metresPerUnit(moscowTile(z: 16))
        XCTAssertEqual(Double(pass?.dashLengthPoints ?? 0) * metres, 1.0, accuracy: 0.05)
        XCTAssertEqual(Double(pass?.dashGapPoints ?? 0) * metres, 1.5, accuracy: 0.05)
        XCTAssertEqual(markingStyle("lane_separator", z: 14).key, 0,
                       "Below the measured street's own level there is no surface to paint on")
    }

    /// Every figure a street is painted with draws at z15 exactly as at z16:
    /// the tile level swap under a moving camera changes the resolution of
    /// the geometry, never which markings exist. What keeps a one-metre dash
    /// off a regional view is the camera-zoom band the paint fades in on, not
    /// the tile level.
    func testTheStreetDrawsTheSameMarkingsAtZ15AsAtZ16() {
        for kind in ["dividing", "lane_separator", "crossing_marked", "bus_lane", "bus_stop_zigzag"] {
            let fine = markingStyle(kind, z: 16)
            let coarse = markingStyle(kind, z: 15)
            XCTAssertEqual(coarse.key, fine.key, "\(kind) draws at z15 under the same baked style")
            XCTAssertEqual(coarse.roadDecorationKind, fine.roadDecorationKind,
                           "\(kind) is built by the same decoration builder at z15")
            XCTAssertEqual(coarse.resolvedLineRenderPasses.count,
                           fine.resolvedLineRenderPasses.count,
                           "\(kind) draws the same passes at z15")
        }
    }

    /// The dash pattern is a length on the ground, so a coarser tile spends
    /// fewer of its units on the same metre: the paint sits still on the
    /// asphalt across the level swap instead of doubling in length.
    func testTheDashPatternIsTheSameLengthOnTheGroundAtEveryTileLevel() {
        for z in [15, 16] {
            let pass = markingStyle("lane_separator", z: z).resolvedLineRenderPasses.first
            let metres = metresPerUnit(moscowTile(z: z))
            XCTAssertEqual(Double(pass?.dashLengthPoints ?? 0) * metres, 1.0, accuracy: 0.05,
                           "One metre of paint at z\(z)")
            XCTAssertEqual(Double(pass?.dashGapPoints ?? 0) * metres, 1.5, accuracy: 0.05,
                           "and one and a half of gap at z\(z)")
        }
    }

    func testASolidLineIsAThickerStrokeThanADashedOne() {
        let solidDividing = markingStyle("dividing", extra: ["style": "solid"])
        let solidPass = solidDividing.resolvedLineRenderPasses.first
        XCTAssertEqual(solidPass?.dashLengthPoints, 0,
                       "A dividing line the source calls solid draws solid")
        XCTAssertNotEqual(solidDividing.key, markingStyle("dividing").key,
                          "under its own key")
        XCTAssertGreaterThan(solidPass?.lineWidthPoints ?? 0,
                             markingStyle("dividing").resolvedLineRenderPasses.first?.lineWidthPoints ?? 99,
                             "A solid line is a statement and draws visibly thicker than a dash row")
    }

    func testAnEdgeLineIsDataOnlyBecauseTheKerbAlreadyDrawsTheEdge() {
        // Every carriageway wears the grey kerb along its outline; a white
        // solid a step inside it doubled the road's edge into two parallel
        // strokes. The shipped edge line therefore draws nothing, in every
        // colour and pattern the source could state it in.
        XCTAssertEqual(markingStyle("edge").key, 0)
        XCTAssertEqual(markingStyle("edge", extra: ["style": "dashed"]).key, 0)
        XCTAssertEqual(markingStyle("edge", extra: ["paint": "yellow"]).key, 0)
    }

    func testCrossingLinesRouteToTheZebraAndUnknownKindsStayHidden() {
        let marked = markingStyle("crossing_marked")
        XCTAssertEqual(marked.roadDecorationKind, .zebraCrossing,
                       "A measured crossing line stripes itself like the tagged ones")
        XCTAssertTrue(marked.isShippedRoadPaint,
                      "and carries the flag, so the surfaces it lies inside never clip it")
        XCTAssertEqual(markingStyle("crossing_unmarked").key, 0,
                       "An unmarked crossing is a place to cross, not a thing to draw")
        XCTAssertEqual(markingStyle("crossing_marked", z: 14).key, 0,
                       "Below the measured street's own level there is no crossing to draw")
        XCTAssertEqual(markingStyle("stop_line").key, 0,
                       "A kind this style does not know yet draws nothing rather than wrong")
    }
}
