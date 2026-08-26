// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

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
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
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
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
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
        let primary = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.layers.roads.primary
        let crossing = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                 properties: ["class": value("primary"),
                                                                              "subclass": value("junction_area"),
                                                                              "origin": value("graph")],
                                                                 tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertTrue(crossing.isRoadSurfaceArea)
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
        XCTAssertFalse(plain.isRoadSurfaceArea)
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

    /// The clip against a surface happens in the space the road lines are
    /// in: raw tile coordinates, y down.
    ///
    /// The rings used to be flipped to render space before the cut, so every
    /// road was clipped against a MIRROR IMAGE of the area: lane lines
    /// survived inside real junction areas (a pile of dashes across every
    /// crossing), and roads at the mirrored spot were phantom-clipped. The
    /// fixture here is deliberately OFF-CENTRE: the original test's square
    /// sat near the tile middle and mirrored onto itself, which is how the
    /// bug shipped.
    func testMarkingsVanishInsideAnAreaAndSurviveAtItsMirror() throws {
        let tileData = VectorTileFixture.layerTile(layerName: "transportation", features: [
            // The crossing near the TOP of the tile (raw y 300...800).
            .init(id: 1,
                  geometry: .polygon(ring: [(1800, 300), (2300, 300), (2300, 800), (1800, 800)]),
                  properties: ["class": "primary", "subclass": "junction_area", "origin": "graph"]),
            // A marked one-way through it.
            .init(id: 2,
                  geometry: .line(points: [(200, 550), (3900, 550)]),
                  properties: ["class": "primary", "lanes": "4", "oneway": "1", "name": "Through Street"]),
            // A second marked one-way at the mirrored raw y: nothing may cut it.
            .init(id: 3,
                  geometry: .line(points: [(200, 3546), (3900, 3546)]),
                  properties: ["class": "primary", "lanes": "4", "oneway": "1", "name": "Mirror Street"]),
        ])
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: tileData)
        let detail = parsed.drawingRoadPhases.automobileGround.detail.drawing

        func detailTriangles(inX xRange: ClosedRange<Float>, y yRange: ClosedRange<Float>) -> Int {
            var count = 0
            var index = 0
            while index + 2 < detail.indices.count {
                let a = detail.vertices[Int(detail.indices[index])]
                let b = detail.vertices[Int(detail.indices[index + 1])]
                let c = detail.vertices[Int(detail.indices[index + 2])]
                let x = (Float(a.position.x) + Float(b.position.x) + Float(c.position.x)) / 3
                let y = (Float(a.position.y) + Float(b.position.y) + Float(c.position.y)) / 3
                if xRange.contains(x), yRange.contains(y) { count += 1 }
                index += 3
            }
            return count
        }

        // Render space flips y: the area is at y 3296...3796 there, and the
        // mirror street runs at y 550.
        XCTAssertEqual(detailTriangles(inX: 1810...2290, y: 3306...3786), 0,
                       "Paint does not run across a junction area")
        XCTAssertGreaterThan(detailTriangles(inX: 500...1500, y: 3400...3700), 0,
                             "and resumes on the road outside it")
        // The mirror street is one long ribbon, so its triangle centroids sit
        // near the thirds of its span, not under the area: sample the whole
        // strip.
        XCTAssertGreaterThan(detailTriangles(inX: 300...3800, y: 450...650), 0,
                             "The road at the area's mirror image is untouched")
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
        for role in [\RoadGeometryPhases<TileMvtParser.DrawingGeometryLayer>.fill,
                     \.casing, \.detail] {
            XCTAssertEqual(withArea.drawingRoadPhases.automobileGround[keyPath: role].drawing.indices.count,
                           bare.drawingRoadPhases.automobileGround[keyPath: role].drawing.indices.count,
                           "The hand-mapped area neither draws nor clips anything")
        }
    }

    /// A street crossed by a chain of small junctions keeps paint between
    /// them. The cut end already stands at the edge of the crossing's gap;
    /// backing off by the half-carriageway inset too ate every short piece,
    /// which is how Mokhovaya lost its markings for three hundred metres.
    func testPaintSurvivesBetweenAChainOfCrossings() throws {
        let tileData = VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1000, 400), (1200, 400), (1200, 700), (1000, 700)]),
                  properties: ["class": "primary", "subclass": "junction_area", "origin": "graph"]),
            .init(id: 2,
                  geometry: .polygon(ring: [(1320, 400), (1520, 400), (1520, 700), (1320, 700)]),
                  properties: ["class": "primary", "subclass": "junction_area", "origin": "graph"]),
            .init(id: 3,
                  geometry: .line(points: [(200, 550), (3900, 550)]),
                  properties: ["class": "primary", "lanes": "4", "oneway": "1", "name": "Chained Street"]),
        ])
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: tileData)
        let detail = parsed.drawingRoadPhases.automobileGround.detail.drawing
        // The piece between the crossings is 120 units, just under 18 m:
        // shorter than two ten-metre insets, so without the suppression the
        // inset maths returns nil and the piece is dropped entirely.
        var betweenCrossings = 0
        var index = 0
        while index + 2 < detail.indices.count {
            let a = detail.vertices[Int(detail.indices[index])]
            let b = detail.vertices[Int(detail.indices[index + 1])]
            let c = detail.vertices[Int(detail.indices[index + 2])]
            let xs = [Float(a.position.x), Float(b.position.x), Float(c.position.x)]
            let ys = [Float(a.position.y), Float(b.position.y), Float(c.position.y)]
            // The piece's vertices sit exactly at the crossings' outlines
            // (1200 and 1320): test that a triangle spans the middle of the
            // gap, not that a vertex falls strictly inside it.
            if xs.min()! < 1260, xs.max()! > 1260, ys.allSatisfy({ $0 > 3396 && $0 < 3696 }),
               xs.max()! - xs.min()! < 400 {
                betweenCrossings += 1
            }
            index += 3
        }
        XCTAssertGreaterThan(betweenCrossings, 0,
                             "Paint runs from one crossing's edge to the next")
    }

    func testATunnelJunctionAreaHasNoKerb() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func value(_ s: String) -> MvtValue { .string(s) }
        let area = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["class": value("service"), "subclass": value("junction_area"), "origin": value("graph"), "brunnel": value("tunnel")],
                                                             tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertNil(area.resolvedLineRenderPasses.first { $0.roadPassRole == .casing })
    }
}
