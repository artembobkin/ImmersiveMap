// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// A road is the theme's symbol, a width in points the tiles cannot change.
/// These tests pin the symbol end to end: the lane count and a stated width
/// say nothing about it, the tile level serving the road changes nothing
/// about it, and nothing is painted on it that the style invents.
final class RoadSymbolWidthTests: XCTestCase {
    private let style = ImmersiveMapTilesDefaultMapStyle(theme: .default)

    /// Central Moscow, the tile column/row of the screenshots this behavior
    /// was reported from, at each zoom.
    private func moscowTile(z: Int) -> Tile {
        let scale = 1 << (z - 16)
        return z >= 16 ? Tile(x: 39616 * scale, y: 20486 * scale, z: z)
                       : Tile(x: 39616 >> (16 - z), y: 20486 >> (16 - z), z: z)
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
                           oneway: Bool = false,
                           width: Int? = nil) -> FeatureStyle {
        var props: [String: MvtValue] = ["class": stringValue(className)]
        if let lanes { props["lanes"] = intValue(lanes) }
        if oneway { props["oneway"] = intValue(1) }
        if let width { props["width"] = intValue(width) }
        return style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                         properties: props,
                                                         tile: moscowTile(z: z)))
    }

    private func fill(_ className: String, lanes: Int? = nil, z: Int, width: Int? = nil) -> TestRoadPass? {
        roadStyle(className, lanes: lanes, z: z, width: width)
            .resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
    }

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

    func testAStreetZoomRoadDrawsKerbless() {
        // The automobile tier carries no casing pass unless the theme asks
        // for one: the road is its fill.
        let featureStyle = roadStyle("primary", lanes: 6, z: 16)
        let passes = featureStyle.resolvedLineRenderPasses
        XCTAssertNotNil(passes.first { $0.roadPassRole == .fill }, "The fill draws")
        XCTAssertNil(passes.first { $0.roadPassRole == .casing }, "and nothing outlines it")
    }

    func testNothingIsPaintedOnASymbol() {
        // The style invents no paint: a lane count, a one-way tag, a wide
        // avenue at street zoom draw the symbol and nothing on it. Paint on
        // a road is what the streetscape measured and ships as its own
        // lines.
        for className in ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"] {
            for lanes in [2, 4, 6] {
                for oneway in [false, true] {
                    let road = roadStyle(className, lanes: lanes, z: 16, oneway: oneway)
                    XCTAssertFalse(road.resolvedLineRenderPasses.contains { $0.roadPassRole == .detail },
                                   "\(className), \(lanes) lanes, oneway \(oneway): nothing painted")
                }
            }
        }
    }

    func testBordersKeepTheirScreenDashes() {
        // A border's dash is a screen pattern in points, which is right for
        // a symbolic line.
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

    func testPaintDrawsOverEveryCarriageway() {
        // The detail role is what puts the measured paint on the asphalt: it
        // sorts above every fill, so a marking is never buried by the road
        // that crosses it.
        XCTAssertGreaterThan(RoadPassRole.detail.rawValue, RoadPassRole.fill.rawValue)
        XCTAssertGreaterThan(RoadPassRole.fill.rawValue, RoadPassRole.casing.rawValue)
    }
}
