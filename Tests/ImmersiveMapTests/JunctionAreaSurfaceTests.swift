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

    /// Two primaries meeting inside a square junction area in the middle of
    /// the tile, at z16 (separate-road rendering is on).
    private func makeTile() throws -> Data {
        try VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .polygon(ring: [(1800, 1800), (2300, 1800), (2300, 2300), (1800, 2300)]),
                  properties: ["class": "primary", "subclass": "junction_area"]),
            .init(id: 2,
                  geometry: .line(points: [(200, 2050), (1800, 2050)]),
                  properties: ["class": "primary", "lanes": "4", "name": "West Street"]),
            .init(id: 3,
                  geometry: .line(points: [(2050, 200), (2050, 1800)]),
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
            .init(id: 2, geometry: .line(points: [(200, 2050), (1800, 2050)]),
                  properties: ["class": "primary", "lanes": "4", "name": "West Street"]),
            .init(id: 3, geometry: .line(points: [(2050, 200), (2050, 1800)]),
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
        let fill = area.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }
        let casing = area.resolvedLineRenderPasses.first { $0.roadPassRole == .casing }
        XCTAssertEqual(fill?.color, ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.layers.roads.primary,
                       "The surface is the primary carriageway color, so ribbons merge into it")
        XCTAssertNotNil(casing, "and it wears a kerb")
        XCTAssertEqual(area.roadClassPriority, 80, "sorted among the primaries")

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

    func testATunnelJunctionAreaHasNoKerb() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func value(_ s: String) -> VectorTile_Tile.Value { var v = VectorTile_Tile.Value(); v.stringValue = s; return v }
        let area = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["class": value("service"), "subclass": value("junction_area"), "brunnel": value("tunnel")],
                                                             tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertNil(area.resolvedLineRenderPasses.first { $0.roadPassRole == .casing })
    }
}
