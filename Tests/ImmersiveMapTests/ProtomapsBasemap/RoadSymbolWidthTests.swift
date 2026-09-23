// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// A road is the theme's symbol, a width in points the tiles cannot change.
/// These tests pin the symbol end to end: a lane count and a stated width
/// say nothing about it, the tile level serving the road changes nothing
/// about it, and nothing is painted on it that the style invents.
final class RoadSymbolWidthTests: XCTestCase {
    private let style = ProtomapsBasemapDefaultMapStyle(theme: .default)

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

    /// The basemap's spelling of the classes the theme names.
    private static let kinds: [String: (kind: String, kindDetail: String)] = [
        "motorway": ("highway", "motorway"),
        "trunk": ("major_road", "trunk"),
        "primary": ("major_road", "primary"),
        "secondary": ("major_road", "secondary"),
        "tertiary": ("major_road", "tertiary"),
        "minor": ("minor_road", "residential"),
        "service": ("minor_road", "service")
    ]

    private func roadStyle(_ className: String,
                           lanes: Int? = nil,
                           z: Int,
                           oneway: Bool = false,
                           width: Int? = nil) -> FeatureStyle {
        var props: [String: MvtValue] = [:]
        if let spelling = Self.kinds[className] {
            props["kind"] = stringValue(spelling.kind)
            props["kind_detail"] = stringValue(spelling.kindDetail)
        } else {
            props["kind"] = stringValue(className)
        }
        // The lane count and the width are not the basemap's, and a source
        // that carries them must change nothing.
        if let lanes { props["lanes"] = intValue(lanes) }
        if oneway { props["oneway"] = .bool(true) }
        if let width { props["width"] = intValue(width) }
        return style.makeStyle(data: DetFeatureStyleData(layerName: "roads",
                                                         properties: props,
                                                         tile: moscowTile(z: z)))
    }

    private func fill(_ className: String, lanes: Int? = nil, z: Int, width: Int? = nil) -> TestRoadPass? {
        roadStyle(className, lanes: lanes, z: z, width: width)
            .resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
    }

    func testTheTilesSayNothingAboutTheWidth() throws {
        let twoLanes = try XCTUnwrap(fill("primary", lanes: 2, z: 15))
        let eightLanes = try XCTUnwrap(fill("primary", lanes: 8, z: 15))
        let stated = try XCTUnwrap(fill("primary", lanes: 8, z: 15, width: 75))
        let symbol = ProtomapsBasemapTheme.RoadMetrics.defaultSymbolWidthPoints.primary
        for pass in [twoLanes, eightLanes, stated] {
            XCTAssertEqual(pass.lineWidthPoints, symbol, "A primary is the theme's symbol whatever the tile carries")
            XCTAssertEqual(pass.lineGeometry.lineWidth, twoLanes.lineGeometry.lineWidth,
                           "and its ribbon hosts the same points")
        }
    }

    func testTheSymbolIsTheSameOnEveryTileZoom() {
        // A symbol is a width on screen, so the tile level serving the road
        // changes nothing about it: neither the points nor the world lock.
        let passes = [13, 14, 15].compactMap { fill("primary", lanes: 6, z: $0) }
        XCTAssertEqual(passes.count, 3)
        for pass in passes {
            XCTAssertEqual(pass.lineWidthPoints, passes[0].lineWidthPoints)
            XCTAssertEqual(pass.pointWidthWorldLockZoom, ProtomapsBasemapTheme.RoadMetrics().worldLockZoom)
        }
    }

    func testAStreetZoomRoadDrawsKerbless() {
        // The automobile tier carries no casing pass unless the theme asks
        // for one: the road is its fill.
        let featureStyle = roadStyle("primary", lanes: 6, z: 15)
        let passes = featureStyle.resolvedLineRenderPasses
        XCTAssertNotNil(passes.first { $0.roadPassRole == .fill }, "The fill draws")
        XCTAssertNil(passes.first { $0.roadPassRole == .casing }, "and nothing outlines it")
    }

    func testNothingIsPaintedOnATwoWaySymbol() {
        // The style invents no paint: a lane count, a wide avenue at street
        // zoom draw the symbol and nothing on it. The one figure it paints
        // is the arrow of a one-way street, from the tiles' own flag.
        for className in ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"] {
            for lanes in [2, 4, 6] {
                let road = roadStyle(className, lanes: lanes, z: 15)
                XCTAssertFalse(road.resolvedLineRenderPasses.contains { $0.roadPassRole == .detail },
                               "\(className), \(lanes) lanes: nothing painted")
                let oneway = roadStyle(className, lanes: lanes, z: 15, oneway: true)
                XCTAssertTrue(oneway.resolvedLineRenderPasses.contains { $0.roadPassRole == .detail },
                              "\(className), one way: the arrows")
            }
        }
    }

    func testBordersKeepTheirScreenDashes() {
        // A border's dash is a screen pattern in points, which is right for
        // a symbolic line.
        let boundary = style.makeStyle(data: DetFeatureStyleData(layerName: "boundaries",
                                                                 properties: ["kind": stringValue("country")],
                                                                 tile: moscowTile(z: 15)))
        XCTAssertFalse(boundary.dashInTileUnits)
        XCTAssertEqual(boundary.dashLengthPoints, 7.0)
    }

    func testAFerryIsAPointLockedDashedStroke() {
        let ferry = roadStyle("ferry", z: 10)
        XCTAssertEqual(ferry.lineWidthPoints, ProtomapsBasemapDefaultMapStyle.ferryWidthPoints)
        XCTAssertEqual(ferry.dashLengthPoints, ProtomapsBasemapDefaultMapStyle.ferryDashPoints)
        XCTAssertFalse(ferry.dashInTileUnits, "a route across water is a screen pattern, not paint on the ground")
        XCTAssertTrue(ferry.suppressPolygonFill)
    }

    func testPaintDrawsOverEveryCarriageway() {
        // The detail role is what puts a decoration on the asphalt: it
        // sorts above every fill, so a figure is never buried by the road
        // that crosses it.
        XCTAssertGreaterThan(RoadPassRole.detail.rawValue, RoadPassRole.fill.rawValue)
        XCTAssertGreaterThan(RoadPassRole.fill.rawValue, RoadPassRole.casing.rawValue)
    }
}
