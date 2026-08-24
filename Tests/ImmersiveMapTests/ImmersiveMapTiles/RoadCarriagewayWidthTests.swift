// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A road's width is a fact about the ground, so the style states it in metres
/// and converts per tile. These tests pin that fact end to end: the same street
/// covers the same metres whichever zoom's tile serves it, the lane count the
/// tiles carry is what sets the width, and an automobile road wide enough to
/// hold a lane divider gets one.
final class RoadCarriagewayWidthTests: XCTestCase {
    private let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

    /// Central Moscow, the tile column/row of the screenshots this behavior
    /// was reported from, at each zoom.
    private func moscowTile(z: Int) -> Tile {
        let scale = 1 << (z - 16)
        return z >= 16 ? Tile(x: 39616 * scale, y: 20486 * scale, z: z)
                       : Tile(x: 39616 >> (16 - z), y: 20486 >> (16 - z), z: z)
    }

    /// Ground metres one tile unit spans, derived independently of the style.
    private func metresPerUnit(_ tile: Tile) -> Double {
        let tilesCount = Double(1 << tile.z)
        let normalizedY = (Double(tile.y) + 0.5) / tilesCount
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * normalizedY)))
        return 40_075_016.686 * cos(latitude) / tilesCount / 4096.0
    }

    private func intValue(_ value: Int) -> VectorTile_Tile.Value {
        var v = VectorTile_Tile.Value()
        v.intValue = Int64(value)
        return v
    }

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var v = VectorTile_Tile.Value()
        v.stringValue = value
        return v
    }

    private func roadStyle(_ className: String,
                           lanes: Int? = nil,
                           z: Int,
                           brunnel: String? = nil) -> FeatureStyle {
        var props: [String: VectorTile_Tile.Value] = ["class": stringValue(className)]
        if let lanes { props["lanes"] = intValue(lanes) }
        if let brunnel { props["brunnel"] = stringValue(brunnel) }
        return style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                         properties: props,
                                                         tile: moscowTile(z: z)))
    }

    private func fillWidthMetres(_ className: String, lanes: Int? = nil, z: Int) -> Double {
        let featureStyle = roadStyle(className, lanes: lanes, z: z)
        let fill = featureStyle.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        return (fill?.parseGeometryStyleData.lineWidth ?? 0) * metresPerUnit(moscowTile(z: z))
    }

    /// A width the tiles state outright wins over any deduction from lanes.
    ///
    /// It comes from the same cross-section model that builds the junction
    /// polygons, and both sides must use one width model: a junction polygon
    /// inside ribbons of a different width floats like a puddle.
    func testAStatedWidthBeatsTheLaneModel() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func widthUnits(_ attributes: [String: Any]) -> Double {
            var properties: [String: VectorTile_Tile.Value] = [:]
            for (key, value) in attributes {
                var wrapped = VectorTile_Tile.Value()
                if let text = value as? String { wrapped.stringValue = text } else if let number = value as? Int { wrapped.intValue = Int64(number) }
                properties[key] = wrapped
            }
            let feature = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                    properties: properties,
                                                                    tile: Tile(x: 39615, y: 20486, z: 16)))
            return feature.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }?.parseGeometryStyleData.lineWidth ?? 0
        }
        // 75 decimetres = 7.5 m; the lane model would say 4 lanes x 4 m = 16 m.
        let stated = widthUnits(["class": "primary", "lanes": 4, "width": 75])
        let deduced = widthUnits(["class": "primary", "lanes": 4])
        XCTAssertGreaterThan(deduced, stated * 1.8,
                             "The stated 7.5 m carriageway draws far narrower than the 16 m the lane model guesses")
        // Nonsense widths fall back to the lane model.
        XCTAssertEqual(widthUnits(["class": "primary", "lanes": 4, "width": 1]), deduced,
                       "Ten centimetres is a data accident, not a road")
        XCTAssertEqual(widthUnits(["class": "primary", "lanes": 4, "width": 900]), deduced,
                       "and so is ninety metres")
    }

    func testCarriagewayWidthIsTheSameGroundWidthAtEveryTileZoom() {
        // The bug this pins: with the width stated in tile units, a street
        // drawn from a coarse tile in the distance came out twice as wide as
        // the same street from the next zoom's tile, and four times as wide
        // as from the one after that.
        let widths = [14, 15, 16].map { fillWidthMetres("primary", lanes: 6, z: $0) }
        for width in widths {
            XCTAssertEqual(width, 6 * 4.0, accuracy: 0.5,
                           "A six-lane primary is six lanes of ground wide at every tile zoom")
        }
        XCTAssertEqual(widths[0], widths[2], accuracy: 0.5)
    }

    func testLaneCountSetsTheWidth() {
        XCTAssertEqual(fillWidthMetres("primary", lanes: 2, z: 16), 2 * 4.0, accuracy: 0.5)
        XCTAssertEqual(fillWidthMetres("primary", lanes: 6, z: 16), 6 * 4.0, accuracy: 0.5)
        XCTAssertGreaterThan(fillWidthMetres("primary", lanes: 6, z: 16),
                             fillWidthMetres("primary", lanes: 2, z: 16))
        // A nonsense lane count cannot swamp the frame.
        XCTAssertLessThan(fillWidthMetres("primary", lanes: 400, z: 16), 60)
    }

    func testUntaggedRoadsFallBackToATypicalLaneCountForTheirClass() {
        // No `lanes` in the tile: the class still states a plausible width,
        // and the hierarchy survives.
        let motorway = fillWidthMetres("motorway", z: 16)
        let minor = fillWidthMetres("minor", z: 16)
        let service = fillWidthMetres("service", z: 16)
        XCTAssertGreaterThan(motorway, minor)
        XCTAssertGreaterThan(minor, service)
        // A counted lane carries its share of the parking strip and gutter,
        // so a two-lane street is around 10 m, not the 6.5 m of two painted lanes.
        XCTAssertEqual(minor, 2 * 5.0, accuracy: 0.5)
    }

    func testAStreetZoomRoadDrawsKerbless() {
        // The automobile tier carries no casing pass: the carriageway is its
        // fill and its paint, and the width stated is the width drawn, with
        // no kerb margin added around it.
        let featureStyle = roadStyle("primary", lanes: 6, z: 16)
        let passes = featureStyle.resolvedLineRenderPasses
        XCTAssertNotNil(passes.first { $0.roadPassRole == .fill }, "The fill draws")
        XCTAssertNil(passes.first { $0.roadPassRole == .casing }, "and nothing outlines it")
    }

    // MARK: - Lane markings

    private func markingPass(_ className: String,
                             lanes: Int? = nil,
                             z: Int,
                             brunnel: String? = nil) -> LineRenderPass? {
        roadStyle(className, lanes: lanes, z: z, brunnel: brunnel)
            .resolvedLineRenderPasses.first { $0.roadPassRole == .detail }
    }

    func testAutomobileRoadsCarryALaneDividerAtStreetZoom() throws {
        let marking = try XCTUnwrap(markingPass("primary", lanes: 6, z: 16),
                                    "An automobile road at street zoom is marked")
        XCTAssertGreaterThan(marking.lineWidthPoints, 0,
                             "The divider is painted on the road: point-locked, so it never grows with it")
        XCTAssertGreaterThan(marking.dashLengthPoints, 0, "and dashed in points")
        XCTAssertGreaterThan(marking.dashGapPoints, 0)
        // The ribbon hosts the point width with margin but stays tight: a
        // wide ribbon is a long corner wedge, the source of the notches seen
        // at every bend of a dashed marking.
        XCTAssertGreaterThanOrEqual(marking.parseGeometryStyleData.lineWidth,
                                    Double(marking.lineWidthPoints) * 4,
                                    "The ribbon must host the point width")
        XCTAssertLessThan(marking.parseGeometryStyleData.lineWidth,
                          Double(marking.lineWidthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint,
                          "and must be far tighter than an overview line's ribbon")
        XCTAssertTrue(marking.parseGeometryStyleData.lineJoinRound,
                      "Round joins fill the corner wedge so a dash across a bend does not notch")
        XCTAssertFalse(marking.parseGeometryStyleData.lineCapRound,
                       "No round caps: the dashes stop on the road instead of laying a disc past its end")

        // The through hierarchy is painted where the tiles state a lane count.
        for className in ["motorway", "trunk", "secondary", "tertiary"] {
            XCTAssertNotNil(markingPass(className, lanes: 4, z: 16),
                            "\(className) is a road of the painted hierarchy")
            XCTAssertNil(markingPass(className, z: 16),
                         "\(className) without a stated lane count has no evidence of paint")
        }
        // Below it, nothing is painted: a residential street and a service
        // alley have bare asphalt whatever they carry.
        for className in ["minor", "service"] {
            XCTAssertNil(markingPass(className, lanes: 4, z: 16),
                         "\(className) carries no painted markings")
        }
    }

    func testLaneDividerIsPaintOnTheGroundNotAScreenPattern() throws {
        // The dash period is a length in metres, so it must come out as the
        // same metres from a z15 tile and a z16 tile of the same street: the
        // dashes sit still and keep their count while the camera zooms and
        // the engine swaps the tile level serving the road. A point-locked
        // pattern would re-flow at every such swap.
        let deep = try XCTUnwrap(markingPass("primary", lanes: 6, z: 16))
        let coarse = try XCTUnwrap(markingPass("primary", lanes: 6, z: 15))
        XCTAssertTrue(deep.dashInTileUnits, "Paint is world-locked: its period is in tile units")
        XCTAssertTrue(coarse.dashInTileUnits)

        let deepMetres = metresPerUnit(moscowTile(z: 16))
        let coarseMetres = metresPerUnit(moscowTile(z: 15))
        let deepDash = Double(deep.dashLengthPoints) * deepMetres
        let coarseDash = Double(coarse.dashLengthPoints) * coarseMetres
        XCTAssertEqual(deepDash, 3.0, accuracy: 0.05, "Three metres of paint")
        XCTAssertEqual(coarseDash, deepDash, accuracy: 0.05,
                       "The same metres whichever tile serves the road")
        XCTAssertEqual(Double(deep.dashGapPoints) * deepMetres, 6.0, accuracy: 0.05, "six of gap")
        // The stroke itself stays a hairline of paint: point-locked width.
        XCTAssertEqual(deep.lineWidthPoints, coarse.lineWidthPoints)
        XCTAssertGreaterThan(deep.lineWidthPoints, 0)
    }

    func testBordersKeepTheirScreenDashes() {
        // The other dash mode is untouched: a border's dash is a screen
        // pattern in points, which is right for a symbolic line.
        let boundary = style.makeStyle(data: DetFeatureStyleData(layerName: "boundary",
                                                                 properties: ["admin_level": intValue(2)],
                                                                 tile: moscowTile(z: 16)))
        XCTAssertFalse(boundary.dashInTileUnits)
        XCTAssertEqual(boundary.dashLengthPoints, 7.0)
    }

    func testNothingElseIsMarked() {
        XCTAssertNil(markingPass("primary", lanes: 6, z: 12),
                     "Below z13 the road is too narrow to hold a divider")
        XCTAssertNotNil(markingPass("primary", lanes: 6, z: 13), "Markings draw from z13")
        XCTAssertNil(markingPass("service", z: 16), "A service road has nothing to divide")
        XCTAssertNil(markingPass("path", z: 16), "A footway is not an automobile road")
        XCTAssertNil(markingPass("primary", lanes: 6, z: 16, brunnel: "tunnel"),
                     "A tunnel's carriageway is not painted")
    }

    func testMarkingsDrawOverEveryCarriageway() {
        // The detail role is what puts the paint on the asphalt: it sorts
        // above every fill, so a marking is never buried by the road that
        // crosses it.
        XCTAssertGreaterThan(RoadPassRole.detail.rawValue, RoadPassRole.fill.rawValue)
        XCTAssertGreaterThan(RoadPassRole.fill.rawValue, RoadPassRole.casing.rawValue)
    }
}
