// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
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

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var v = VectorTile_Tile.Value()
        v.stringValue = value
        return v
    }

    private func markingStyle(_ kind: String, z: Int = 16,
                              extra: [String: String] = [:]) -> FeatureStyle {
        var props: [String: VectorTile_Tile.Value] = ["marking": stringValue(kind)]
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

    func testALaneSeparatorIsAOneMetreDashAndOnlyAtStreetZoom() {
        let separator = markingStyle("lane_separator")
        let pass = separator.resolvedLineRenderPasses.first
        XCTAssertEqual(pass?.key, 58)
        let metres = metresPerUnit(moscowTile(z: 16))
        XCTAssertEqual(Double(pass?.dashLengthPoints ?? 0) * metres, 1.0, accuracy: 0.05)
        XCTAssertEqual(Double(pass?.dashGapPoints ?? 0) * metres, 1.5, accuracy: 0.05)
        XCTAssertEqual(markingStyle("lane_separator", z: 15).key, 0,
                       "A one-metre pattern is sub-pixel mush a level coarser: hidden at z15")
        XCTAssertNotEqual(markingStyle("dividing", z: 15).key, 0,
                          "while the longer figures draw from the zoom the tiles ship them at")
    }

    func testASolidLineIsAThickerStrokeThanADashedOne() {
        let edge = markingStyle("edge")
        let pass = edge.resolvedLineRenderPasses.first
        XCTAssertEqual(pass?.key, 59)
        XCTAssertEqual(pass?.dashLengthPoints, 0, "An edge line is solid")
        XCTAssertGreaterThan(pass?.lineWidthPoints ?? 0,
                             markingStyle("dividing").resolvedLineRenderPasses.first?.lineWidthPoints ?? 99,
                             "A solid line is a statement and draws visibly thicker than a dash row")
        let dashedEdge = markingStyle("edge", extra: ["style": "dashed"])
        XCTAssertGreaterThan(dashedEdge.resolvedLineRenderPasses.first?.dashLengthPoints ?? 0, 0,
                             "unless the source says it is dashed")
        XCTAssertNotEqual(dashedEdge.key, edge.key,
                          "and then it is its own baked style, at the dash weight")
        let solidDividing = markingStyle("dividing", extra: ["style": "solid"])
        let solidPass = solidDividing.resolvedLineRenderPasses.first
        XCTAssertEqual(solidPass?.dashLengthPoints, 0,
                       "A dividing line the source calls solid draws solid")
        XCTAssertNotEqual(solidDividing.key, markingStyle("dividing").key,
                          "under its own key")
        XCTAssertGreaterThan(solidPass?.lineWidthPoints ?? 0,
                             markingStyle("dividing").resolvedLineRenderPasses.first?.lineWidthPoints ?? 99,
                             "and thicker than its broken form")
    }

    func testCrossingLinesRouteToTheZebraAndUnknownKindsStayHidden() {
        let marked = markingStyle("crossing_marked")
        XCTAssertEqual(marked.roadDecorationKind, .zebraCrossing,
                       "A measured crossing line stripes itself like the tagged ones")
        XCTAssertTrue(marked.isShippedRoadPaint,
                      "and carries the flag, so the surfaces it lies inside never clip it")
        XCTAssertEqual(markingStyle("crossing_unmarked").key, 0,
                       "An unmarked crossing is a place to cross, not a thing to draw")
        XCTAssertEqual(markingStyle("crossing_marked", z: 15).key, 0,
                       "A crossing is a smudge a level below z16")
        XCTAssertEqual(markingStyle("stop_line").key, 0,
                       "A kind this style does not know yet draws nothing rather than wrong")
    }
}
