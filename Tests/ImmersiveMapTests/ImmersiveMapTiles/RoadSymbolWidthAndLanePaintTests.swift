// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// A road is the theme's symbol, a width in points the tiles cannot change,
/// and the paint on it is laid across that symbol. These tests pin the
/// symbol end to end: the lane count says nothing about the width, the
/// symbol's ground width is the same metres whichever zoom's tile serves the
/// road, and an automobile road with a stated lane count carries its lane
/// paint across the symbol.
final class RoadSymbolWidthAndLanePaintTests: XCTestCase {
    private let style = ImmersiveMapTilesDefaultMapStyle(theme: .default)

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

    private func intValue(_ value: Int) -> MvtValue {
        .int(Int64(value))
    }

    private func stringValue(_ value: String) -> MvtValue {
        .string(value)
    }

    private func roadStyle(_ className: String,
                           lanes: Int? = nil,
                           z: Int,
                           brunnel: String? = nil,
                           width: Int? = nil) -> FeatureStyle {
        var props: [String: MvtValue] = ["class": stringValue(className)]
        if let lanes { props["lanes"] = intValue(lanes) }
        if let brunnel { props["brunnel"] = stringValue(brunnel) }
        if let width { props["width"] = intValue(width) }
        return style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                         properties: props,
                                                         tile: moscowTile(z: z)))
    }

    private func fill(_ className: String, lanes: Int? = nil, z: Int, width: Int? = nil) -> TestRoadPass? {
        roadStyle(className, lanes: lanes, z: z, width: width)
            .resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
    }

    // MARK: - The symbol

    func testTheTilesSayNothingAboutTheWidth() throws {
        let twoLanes = try XCTUnwrap(fill("primary", lanes: 2, z: 16))
        let eightLanes = try XCTUnwrap(fill("primary", lanes: 8, z: 16))
        let stated = try XCTUnwrap(fill("primary", lanes: 8, z: 16, width: 75))
        let symbol = ImmersiveMapTilesTheme.RoadMetrics.defaultSymbolWidthPoints.primary
        for pass in [twoLanes, eightLanes, stated] {
            XCTAssertEqual(pass.lineWidthPoints, symbol, "A primary is the theme's symbol whatever the tile carries")
            XCTAssertEqual(pass.lineGeometry.lineWidth, twoLanes.lineGeometry.lineWidth,
                           "and its ribbon hosts the same points")
        }
    }

    func testTheSymbolIsTheSameOnEveryTileZoom() {
        // A symbol is a width on screen, so the tile level serving the road
        // changes nothing about it: neither the points nor the world lock.
        let passes = [13, 14, 15, 16].compactMap { fill("primary", lanes: 6, z: $0) }
        XCTAssertEqual(passes.count, 4)
        for pass in passes {
            XCTAssertEqual(pass.lineWidthPoints, passes[0].lineWidthPoints)
            XCTAssertEqual(pass.pointWidthWorldLockZoom, ImmersiveMapTilesTheme.RoadMetrics().worldLockZoom)
        }
    }

    func testTheSymbolsGroundWidthIsTheSameMetresAtEveryTileZoom() {
        // The paint is laid across the symbol's ground width, the width its
        // points cover at the world lock zoom, converted per tile: so a z15
        // tile and a z16 tile of the same street state the same metres, and
        // the lane lines sit still when the engine swaps the tile level.
        let widths = [14, 15, 16].map {
            style.symbolGroundWidthUnits(cls: "primary", tile: moscowTile(z: $0)) * metresPerUnit(moscowTile(z: $0))
        }
        XCTAssertEqual(widths[0], widths[2], accuracy: 0.01)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.01)
        XCTAssertGreaterThan(widths[2], 1, "a primary is a few metres of ground at the lock")
        XCTAssertLessThan(widths[2], 20)
        // The ladder holds on the ground as it does on screen.
        let motorway = style.symbolGroundWidthUnits(cls: "motorway", tile: moscowTile(z: 16))
        let minor = style.symbolGroundWidthUnits(cls: "minor", tile: moscowTile(z: 16))
        let service = style.symbolGroundWidthUnits(cls: "service", tile: moscowTile(z: 16))
        XCTAssertGreaterThan(motorway, minor)
        XCTAssertGreaterThan(minor, service)
    }

    func testTheGroundWidthFollowsTheThemesSymbolAndLock() {
        let tile = moscowTile(z: 16)
        let wider = ImmersiveMapTilesDefaultMapStyle(
            theme: ImmersiveMapTilesTheme.default.roadMetrics { $0.symbolWidthPoints.primary *= 2 })
        XCTAssertEqual(wider.symbolGroundWidthUnits(cls: "primary", tile: tile),
                       style.symbolGroundWidthUnits(cls: "primary", tile: tile) * 2,
                       accuracy: 1e-9,
                       "Twice the points is twice the ground")
        let later = ImmersiveMapTilesDefaultMapStyle(
            theme: ImmersiveMapTilesTheme.default.roadMetrics { $0.worldLockZoom += 1 })
        XCTAssertEqual(later.symbolGroundWidthUnits(cls: "primary", tile: tile),
                       style.symbolGroundWidthUnits(cls: "primary", tile: tile) * 0.5,
                       accuracy: 1e-9,
                       "A lock one zoom later freezes the same points on half the ground")
        let never = ImmersiveMapTilesDefaultMapStyle(
            theme: ImmersiveMapTilesTheme.default.roadMetrics { $0.worldLockZoom = 0 })
        XCTAssertEqual(never.symbolGroundZoom, Float(LowZoomOverviewFade.roadMarkingStartZoom),
                       "A symbol never frozen is measured where its paint comes in")
    }

    func testAStreetZoomRoadDrawsKerbless() {
        // The automobile tier carries no casing pass unless the theme asks
        // for one: the road is its fill and its paint.
        let featureStyle = roadStyle("primary", lanes: 6, z: 16)
        let passes = featureStyle.resolvedLineRenderPasses
        XCTAssertNotNil(passes.first { $0.roadPassRole == .fill }, "The fill draws")
        XCTAssertNil(passes.first { $0.roadPassRole == .casing }, "and nothing outlines it")
    }

    // MARK: - Lane markings

    private func markingPass(_ className: String,
                             lanes: Int? = nil,
                             z: Int,
                             brunnel: String? = nil) -> TestRoadPass? {
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
        XCTAssertGreaterThanOrEqual(marking.lineGeometry.lineWidth,
                                    Double(marking.lineWidthPoints) * 4,
                                    "The ribbon must host the point width")
        XCTAssertLessThan(marking.lineGeometry.lineWidth,
                          Double(marking.lineWidthPoints) * FeatureStyle.pointLockedRibbonUnitsPerPoint,
                          "and must be far tighter than an overview line's ribbon")
        XCTAssertTrue(marking.lineGeometry.lineJoinRound,
                      "Round joins fill the corner wedge so a dash across a bend does not notch")
        XCTAssertFalse(marking.lineGeometry.lineCapRound,
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

    func testLaneLinesDivideTheSymbolsGroundWidth() throws {
        // A one-way avenue of four lanes: three boundaries, evenly spaced
        // across the symbol's ground width, the outer ones a lane in from
        // its edges. The same width divided the same way from a z15 tile,
        // in that tile's units.
        for z in [15, 16] {
            let tile = moscowTile(z: z)
            var props: [String: MvtValue] = ["class": stringValue("primary"),
                                             "lanes": intValue(4),
                                             "oneway": intValue(1)]
            props["lanes_src"] = stringValue("tagged")
            let passes = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                   properties: props,
                                                                   tile: tile))
                .resolvedLineRenderPasses.filter { $0.roadPassRole == .detail }
            let offsets = Set(passes.map { $0.lineGeometry.lateralOffset }).sorted()
            let width = style.symbolGroundWidthUnits(cls: "primary", tile: tile)
            XCTAssertEqual(offsets.count, 3, "four lanes, three boundaries")
            for (offset, expected) in zip(offsets, [-width * 0.25, 0, width * 0.25]) {
                XCTAssertEqual(offset, expected, accuracy: 1e-9, "evenly spaced across the symbol")
            }
            for pass in passes {
                XCTAssertEqual(pass.lineGeometry.endInset, width * 0.5, accuracy: 1e-9,
                               "and the paint stops half the symbol short of a junction")
            }
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

    func testAFerryIsAPointLockedDashedStroke() {
        let ferry = roadStyle("ferry", z: 10)
        XCTAssertEqual(ferry.lineWidthPoints, ImmersiveMapTilesDefaultMapStyle.ferryWidthPoints)
        XCTAssertEqual(ferry.dashLengthPoints, ImmersiveMapTilesDefaultMapStyle.ferryDashPoints)
        XCTAssertFalse(ferry.dashInTileUnits, "a route across water is a screen pattern, not paint on the ground")
        XCTAssertTrue(ferry.suppressPolygonFill)
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
