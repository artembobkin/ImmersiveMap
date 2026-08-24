// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A junction area (`subclass=junction_area`, a polygon in `transportation`)
/// is the carriageway of a junction as the tiles map it. The parser routes it
/// into the automobile road phases, its fill as the surface and its outline as
/// the kerb, so it sorts among the roads of its class and covers the kerbs of
/// the ribbons that enter it; it never falls to the ground polygons.
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
        try VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1800, 900), (2300, 900), (2300, 1400), (1800, 1400)]),
                  properties: ["class": "primary", "subclass": "junction_area"]),
            .init(id: 2,
                  geometry: .line(points: [(200, 1150), (1800, 1150)]),
                  properties: ["class": "primary", "lanes": "4", "name": "West Street"]),
            .init(id: 3,
                  geometry: .line(points: [(2050, 200), (2050, 900)]),
                  properties: ["class": "primary", "lanes": "4", "name": "North Street"]),
        ])
    }

    func testJunctionAreaDrawsInTheAutomobileTierAsSurfaceAndKerb() throws {
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: makeTile())
        let automobile = parsed.drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(automobile.fill.drawing.indices.count, 0, "The surface draws in the fill role")
        XCTAssertGreaterThan(automobile.casing.drawing.indices.count, 0, "The kerb draws in the casing role")
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

    func testJunctionAreaTakesTheColorOfItsClass() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func value(_ s: String) -> VectorTile_Tile.Value { var v = VectorTile_Tile.Value(); v.stringValue = s; return v }
        let area = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["class": value("primary"), "subclass": value("junction_area")],
                                                             tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertTrue(area.isRoadSurfaceArea)
        let primary = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.layers.roads.primary
        // Hand-mapped area:highway: the carriageway of a whole street, so it
        // stays in the class colour and leaves the street's paint alone.
        let fill = area.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        XCTAssertEqual(fill?.color, primary,
                       "A hand-mapped carriageway area merges into the ribbons of its class")
        XCTAssertFalse(area.surfaceAreaCutsPaint, "and the street inside it keeps its markings")
        XCTAssertNotNil(area.resolvedLineRenderPasses.first { $0.roadPassRole == .casing }, "and it wears a kerb")
        XCTAssertEqual(area.roadClassPriority, 80, "sorted among the primaries")

        // A crossing reconstructed from the graph: the same asphalt, no tone
        // of its own. The reconstructed polygons overlap each other and the
        // ribbons, and any distinct tone draws every overlap as a seam; what
        // sets a crossing apart is only that no lane paint runs inside it.
        let crossing = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                 properties: ["class": value("primary"),
                                                                              "subclass": value("junction_area"),
                                                                              "origin": value("graph")],
                                                                 tile: Tile(x: 39615, y: 20486, z: 16)))
        let crossingFill = crossing.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        XCTAssertEqual(crossingFill?.color, primary,
                       "The crossing is exactly the class colour")
        XCTAssertEqual(crossingFill?.key, fill?.key,
                       "and shares the class fill key, so overlaps cannot differ")
        XCTAssertTrue(crossing.surfaceAreaCutsPaint, "and it cuts the paint of the roads inside it")

        // A plain road polygon (no junction_area subclass) is untouched.
        let plain = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                              properties: ["class": value("primary")],
                                                              tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertFalse(plain.isRoadSurfaceArea)
    }

    /// The kerb traces the area's own outline.
    ///
    /// The rings reach the kerb pass in render space (y already flipped) and
    /// the line tessellator flips again, so a ring handed over unconverted
    /// drew the kerb mirrored about the tile's mid-line: a dark outline lying
    /// across whatever was there, and no kerb at the junction. The area in the
    /// fixture sits in the upper half of the tile, where a mirrored kerb lands
    /// in the lower half and this assertion catches it.
    func testJunctionAreaKerbFollowsTheAreaOutline() throws {
        let tileData = try VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1800, 600), (2300, 600), (2300, 1100), (1800, 1100)]),
                  properties: ["class": "primary", "subclass": "junction_area"]),
        ])
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: tileData)
        let kerb = parsed.drawingRoadPhases.automobileGround.casing.drawing
        XCTAssertGreaterThan(kerb.vertices.count, 0, "the area wears a kerb")

        // The polygon in render space: y flips, so the ring spans y 2996...3496.
        let margin: Float = 40
        for vertex in kerb.vertices {
            let x = Float(vertex.position.x)
            let y = Float(vertex.position.y)
            XCTAssertTrue(x >= 1800 - margin && x <= 2300 + margin,
                          "kerb vertex x=\(x) is outside the area it belongs to")
            XCTAssertTrue(y >= 2996 - margin && y <= 3496 + margin,
                          "kerb vertex y=\(y) is outside the area it belongs to: a mirrored kerb lands near y=\(4096 - y)")
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
        let tileData = try VectorTileFixture.layerTile(layerName: "transportation", features: [
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

    /// A hand-mapped carriageway area covers a whole street, and the street
    /// keeps its markings inside it; only a reconstructed crossing cuts them.
    func testAHandMappedAreaDoesNotCutTheStreetsPaint() throws {
        let tileData = try VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1500, 300), (2600, 300), (2600, 800), (1500, 800)]),
                  properties: ["class": "primary", "subclass": "junction_area"]),
            .init(id: 2,
                  geometry: .line(points: [(200, 550), (3900, 550)]),
                  properties: ["class": "primary", "lanes": "4", "oneway": "1", "name": "Through Street"]),
        ])
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: tileData)
        let detail = parsed.drawingRoadPhases.automobileGround.detail.drawing
        // The paint is one continuous ribbon through the area, so its
        // vertices sit at the street's ends: test that a triangle SPANS the
        // area, not that a centroid lands inside it.
        var spansArea = 0
        var index = 0
        while index + 2 < detail.indices.count {
            let a = detail.vertices[Int(detail.indices[index])]
            let b = detail.vertices[Int(detail.indices[index + 1])]
            let c = detail.vertices[Int(detail.indices[index + 2])]
            let xs = [Float(a.position.x), Float(b.position.x), Float(c.position.x)]
            let ys = [Float(a.position.y), Float(b.position.y), Float(c.position.y)]
            if xs.min()! < 1500, xs.max()! > 2600, ys.allSatisfy({ $0 > 3306 && $0 < 3786 }) {
                spansArea += 1
            }
            index += 3
        }
        XCTAssertGreaterThan(spansArea, 0,
                             "The street keeps its lane lines over the hand-mapped carriageway")
    }

    /// A street crossed by a chain of small junctions keeps paint between
    /// them. The cut end already stands at the edge of the crossing's gap;
    /// backing off by the half-carriageway inset too ate every short piece,
    /// which is how Mokhovaya lost its markings for three hundred metres.
    func testPaintSurvivesBetweenAChainOfCrossings() throws {
        let tileData = try VectorTileFixture.layerTile(layerName: "transportation", features: [
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
        func value(_ s: String) -> VectorTile_Tile.Value { var v = VectorTile_Tile.Value(); v.stringValue = s; return v }
        let area = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["class": value("service"), "subclass": value("junction_area"), "brunnel": value("tunnel")],
                                                             tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertNil(area.resolvedLineRenderPasses.first { $0.roadPassRole == .casing })
    }
}
