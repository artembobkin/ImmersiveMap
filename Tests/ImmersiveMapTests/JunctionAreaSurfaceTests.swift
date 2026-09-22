// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

/// A junction area (`subclass=junction_area`, a polygon in `transportation`)
/// is the carriageway of a junction. Only the graph-reconstructed ones
/// (`origin=graph`) draw: the parser routes them into the automobile road
/// phases as the surface fill, sorted among the roads of their class and
/// kerbless like the whole automobile tier (the roadway is held by its fill
/// and its paint, not an outline). A hand-mapped `area:highway` is ignored: in central
/// Moscow it often covers a whole street including the gap between the two
/// halves of a dual carriageway, welding the reconstructed bodies together.
final class JunctionAreaSurfaceTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        TileMvtParser.forTests(settings: .default)
    }

    /// Two primaries meeting inside a square junction area, at z16
    /// (separate-road rendering is on). The square sits OFF the tile centre
    /// on purpose: a fixture symmetric about the y mirror line lands back on
    /// itself when a mirror bug ships, which is exactly how one shipped.
    private func makeTile() throws -> Data {
        VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1800, 900), (2300, 900), (2300, 1400), (1800, 1400)]),
                  properties: ["class": "primary", "subclass": "junction_area", "origin": "graph"]),
            .init(id: 2,
                  geometry: .line(points: [(200, 1150), (1800, 1150)]),
                  properties: ["class": "primary", "lanes": "4", "name": "West Street"]),
            .init(id: 3,
                  geometry: .line(points: [(2050, 200), (2050, 900)]),
                  properties: ["class": "primary", "lanes": "4", "name": "North Street"]),
        ])
    }

    func testJunctionAreaDrawsInTheAutomobileTierAsSurface() throws {
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: makeTile())
        let automobile = parsed.drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(automobile.fill.drawing.indices.count, 0, "The surface draws in the fill role")
        XCTAssertEqual(automobile.casing.drawing.indices.count, 0,
                       "and nothing draws in the casing role: the automobile tier is kerbless")
        // The ground polygons carry only what the parser always emits (the
        // synthetic background quad); the area itself is not among them. A
        // control parse of the same tile without the area pins the baseline.
        let control = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16),
                                             mvtData: VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 2, geometry: .line(points: [(200, 1150), (1800, 1150)]),
                  properties: ["class": "primary", "lanes": "4", "name": "West Street"]),
            .init(id: 3, geometry: .line(points: [(2050, 200), (2050, 900)]),
                  properties: ["class": "primary", "lanes": "4", "name": "North Street"]),
        ]))
        XCTAssertEqual(parsed.drawingPolygon.indices.count, control.drawingPolygon.indices.count,
                       "A road surface area adds nothing to the ground polygons")
        XCTAssertGreaterThan(automobile.fill.drawing.indices.count, control.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                             "It adds its surface to the automobile fill")
        XCTAssertEqual(parsed.drawingRoadPhases.ground.fill.drawing.indices.count, 0,
                       "and nothing to the pedestrian tier")
    }

    func testAHandMappedAreaIsIgnoredAndAGraphOneWearsTheClassColour() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(theme: .default)
        func value(_ s: String) -> MvtValue { .string(s) }
        // Hand-mapped area:highway: ignored. In central Moscow it often
        // covers a whole street including the gap between the two halves of
        // a dual carriageway, welding the reconstructed bodies into one mass
        // with both inner edge lines stranded inside it.
        let handMapped = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                   properties: ["class": value("primary"), "subclass": value("junction_area")],
                                                                   tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertEqual(handMapped.key, 0, "A hand-mapped area draws nothing")

        // A surface reconstructed from the graph: the same asphalt, no tone
        // of its own, no kerb (the automobile tier is kerbless), and it cuts
        // the paint of the roads inside it, because the measured paint ships
        // as its own lines.
        let primary = ImmersiveMapTilesTheme.default.layers.roads.primary
        let crossing = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                 properties: ["class": value("primary"),
                                                                              "subclass": value("junction_area"),
                                                                              "origin": value("graph")],
                                                                 tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertEqual(ImmersiveMapTilesSchema().facts(layerName: "transportation",
                                                       properties: ["subclass": value("junction_area"), "origin": value("graph")],
                                                       tile: Tile(x: 39615, y: 20486, z: 16)).road?.kind,
                       .surface(reconstructed: true),
                       "A graph junction area is read as a reconstructed surface")
        let crossingFill = crossing.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        XCTAssertEqual(crossingFill?.color, primary,
                       "The crossing is exactly the class colour")
        XCTAssertNil(crossing.resolvedLineRenderPasses.first { $0.roadPassRole == .casing },
                     "and wears no kerb")
        XCTAssertTrue(crossing.surfaceAreaCutsPaint, "and it cuts the paint of the roads inside it")
        XCTAssertEqual(crossing.roadClassPriority, 80, "sorted among the primaries")

        // A plain road polygon (no junction_area subclass) is untouched.
        let plain = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                              properties: ["class": value("primary")],
                                                              tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertEqual(ImmersiveMapTilesSchema().facts(layerName: "transportation",
                                                       properties: ["class": value("primary")],
                                                       tile: Tile(x: 39615, y: 20486, z: 16)).road?.kind,
                       .centreline)
        XCTAssertFalse(plain.surfaceAreaCutsPaint)
    }

    /// The surface traces the area's own outline (the mirror guard that used
    /// to watch the kerb, moved to the fill when the automobile tier went
    /// kerbless): a ring handed to the tessellator unconverted lands
    /// mirrored about the tile's mid-line. The area in the fixture sits in
    /// the upper half of the tile, where a mirrored surface lands in the
    /// lower half and this assertion catches it.
    func testJunctionAreaSurfaceFollowsTheAreaOutline() throws {
        let tileData = VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1800, 600), (2300, 600), (2300, 1100), (1800, 1100)]),
                  properties: ["class": "primary", "subclass": "junction_area", "origin": "graph"]),
        ])
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: tileData)
        let surface = parsed.drawingRoadPhases.automobileGround.fill.drawing
        XCTAssertGreaterThan(surface.vertices.count, 0, "the area draws its surface")

        // The polygon in render space: y flips, so the ring spans y 2996...3496.
        let margin: Float = 40
        for vertex in surface.vertices {
            let x = Float(vertex.position.x)
            let y = Float(vertex.position.y)
            XCTAssertTrue(x >= 1800 - margin && x <= 2300 + margin,
                          "surface vertex x=\(x) is outside the area it belongs to")
            XCTAssertTrue(y >= 2996 - margin && y <= 3496 + margin,
                          "surface vertex y=\(y) is outside the area it belongs to: a mirrored surface lands near y=\(4096 - y)")
        }
    }

    /// A hand-mapped carriageway area is invisible: the tile still ships it,
    /// and the frame is exactly what it would be without it, so the street
    /// keeps its ribbon, its kerbs and its paint.
    func testAHandMappedAreaChangesNothing() throws {
        let street = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(200, 550), (3900, 550)]),
            properties: ["class": "primary", "lanes": "4", "oneway": "1", "name": "Through Street"])
        let withArea = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16),
                                              mvtData: VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1500, 300), (2600, 300), (2600, 800), (1500, 800)]),
                  properties: ["class": "primary", "subclass": "junction_area"]),
            street,
        ]))
        let bare = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16),
                                          mvtData: VectorTileFixture.layerTile(layerName: "transportation",
                                                                               features: [street]))
        for role in [\RoadGeometryPhases<DrawingGeometryLayer>.fill,
                     \.casing, \.detail] {
            XCTAssertEqual(withArea.drawingRoadPhases.automobileGround[keyPath: role].drawing.indices.count,
                           bare.drawingRoadPhases.automobileGround[keyPath: role].drawing.indices.count,
                           "The hand-mapped area neither draws nor clips anything")
        }
    }

    func testATunnelJunctionAreaHasNoKerb() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(theme: .default)
        func value(_ s: String) -> MvtValue { .string(s) }
        let area = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["class": value("service"), "subclass": value("junction_area"), "origin": value("graph"), "brunnel": value("tunnel")],
                                                             tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertNil(area.resolvedLineRenderPasses.first { $0.roadPassRole == .casing })
    }

    /// A tunnel is a bare translucent fill wherever it draws: the surface
    /// at street zoom, the ribbon at the zooms a road is a line, the
    /// point-locked stroke over a region. Same opacity, no dash, no paint.
    func testATunnelIsATranslucentFillAtEveryZoom() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(theme: .default)
        let service = ImmersiveMapTilesTheme.default.layers.roads.service
        func value(_ s: String) -> MvtValue { .string(s) }
        func make(_ properties: [String: MvtValue], z: Int) -> FeatureStyle {
            style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                      properties: properties,
                                                      tile: Tile(x: 39615 >> (16 - z), y: 20486 >> (16 - z), z: z)))
        }
        let opacity = ImmersiveMapTilesDefaultMapStyle.tunnelFillOpacity
        XCTAssertEqual(opacity, 0.2, accuracy: 1e-6, "Eighty percent transparent")

        let surface = make(["class": value("service"), "subclass": value("carriageway_area"),
                            "origin": value("graph"), "brunnel": value("tunnel")], z: 16)
        let surfaceFill = try XCTUnwrap(surface.resolvedLineRenderPasses.first { $0.roadPassRole == .fill })
        XCTAssertEqual(surfaceFill.color, SIMD4<Float>(service.x, service.y, service.z, opacity),
                       "The surface is the class colour at the tunnel opacity")
        XCTAssertEqual(surface.resolvedLineRenderPasses.count, 1, "and nothing else draws on it")

        let ribbon = make(["class": value("primary"), "lanes": value("4"), "oneway": value("1"),
                           "brunnel": value("tunnel")], z: 14)
        let ribbonFill = try XCTUnwrap(ribbon.resolvedLineRenderPasses.first { $0.roadPassRole == .fill })
        XCTAssertEqual(ribbonFill.color.w, opacity, accuracy: 1e-6, "The ribbon carries the tunnel opacity")
        XCTAssertFalse(ribbonFill.lineGeometry.usesDashPattern, "and is no longer dashed")
        XCTAssertFalse(ribbonFill.lineGeometry.lineCapRound,
                       "and ends flat: a round cap on the stub the surface leaves bulged back over the tunnel")
        XCTAssertNil(ribbon.resolvedLineRenderPasses.first { $0.roadPassRole == .casing }, "no kerb")
        XCTAssertNil(ribbon.resolvedLineRenderPasses.first { $0.roadPassRole == .detail }, "no paint")

        let overview = make(["class": value("motorway"), "brunnel": value("tunnel")], z: 8)
        XCTAssertEqual(overview.color.w, opacity, accuracy: 1e-6, "The overview stroke carries the tunnel opacity")
        XCTAssertFalse(overview.lineGeometry.usesDashPattern, "and is not dashed either")
    }
}
