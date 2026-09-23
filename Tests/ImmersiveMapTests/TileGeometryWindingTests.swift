// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The winding contract of the tile geometry, checked through the whole
/// parser: every triangle of the ground, the bridge overlay and every road
/// bucket is counter-clockwise in render space, the front face the tile
/// drawers keep when they cull back faces. Each emitter keeps the contract
/// by construction; this pins that none of them slipped, on a coarse tile
/// (fills with holes, the ocean split, the overview road stroke with its
/// round joins and caps, the background quad, the debug borders) and on a
/// street tile (ribbons and kerbs).
final class TileGeometryWindingTests: XCTestCase {
    private static let coarseTile = WebMercatorTileScheme.tile(latitude: 55.75, longitude: 37.61, z: 6)
    private static let streetTile = Tile(x: 19807, y: 10243, z: 15)

    private func makeParser(addTestBorders: Bool = false) -> TileMvtParser {
        var config = ImmersiveMapSettings.default
        config.tiles.parsing.addTestBorders = addTestBorders
        return TileMvtParser.forTests(settings: config)
    }

    private func assertCounterClockwise(_ drawing: DrawingPolygonBytes,
                                        _ name: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        let positions = drawing.vertices.map(\.position)
        let triangles = drawing.indices
        if let triangle = ParsedPolygon.firstClockwiseTriangle(vertices: positions,
                                                                             indices: triangles) {
            XCTFail("\(name): triangle \(triangle) of \(triangles.count / 3) is clockwise",
                    file: file, line: line)
        }
    }

    /// A square shell with positive signed area in tile units; reversed, a hole.
    private static func square(_ x0: Int32, _ y0: Int32, _ side: Int32) -> [(Int32, Int32)] {
        [(x0, y0), (x0 + side, y0), (x0 + side, y0 + side), (x0, y0 + side)]
    }

    func testCoarseTileGroundAndBridgeGeometryIsCounterClockwise() throws {
        let parser = makeParser(addTestBorders: true)
        // Sixty-four holes take the ocean through its split into water plus
        // land-from-holes; one hole takes a fill through earcut's bridging.
        // Every layer is one the style draws at z6 (water, the global
        // landcover, the motorway skeleton); a control parse of an empty
        // layer pins what the parser emits on its own, the background and
        // the debug borders, so each layer is checked to add to it.
        let holes: [[(Int32, Int32)]] = (0..<GroundFeatureReader.complexOceanHoleSplitThreshold).map { index in
            Array(Self.square(200 + Int32(index % 8) * 450, 200 + Int32(index / 8) * 450, 200).reversed())
        }
        let layers: [(name: String, features: [VectorTileFixture.Feature])] = [
            ("water", [.init(id: 1,
                             geometry: .polygonWithHoles(exterior: Self.square(0, 0, 4096), interiors: holes),
                             properties: ["class": "ocean"])]),
            ("water", [.init(id: 1,
                             geometry: .polygonWithHoles(exterior: Self.square(100, 100, 3000),
                                                         interiors: [Array(Self.square(1000, 1000, 800).reversed())]),
                             properties: ["class": "ocean"])]),
            ("landcover", [.init(id: 1,
                                 geometry: .polygon(ring: Self.square(300, 300, 1500)),
                                 properties: ["kind": "forest"]),
                           .init(id: 2,
                                 geometry: .polygon(ring: [(2000, 2000), (3800, 2000), (3800, 3800),
                                                           (2900, 2600), (2000, 3800)]),
                                 properties: ["kind": "grassland"])]),
            // The overview stroke with round joins and caps: a right and a
            // left turn inside the tile, a bend leaving the tile (the clip
            // re-fans it), and a bridge, which the overview stroke draws like
            // any other road (the bridge overlay begins at street zooms).
            ("roads", [.road(id: 1, kind: "highway", kindDetail: "motorway",
                             points: [(300, 3000), (1200, 3000), (1200, 3600), (2000, 3600)]),
                       .road(id: 2, kind: "highway", kindDetail: "motorway",
                             points: [(2500, 500), (3500, 500), (3500, 1500), (4500, 1500)]),
                       .road(id: 3, kind: "highway", kindDetail: "motorway",
                             points: [(500, 800), (1500, 1200)], extra: ["is_bridge": "true"])])
        ]
        let backgroundOnly = try parser.parse(tile: Self.coarseTile,
                                              mvtData: VectorTileFixture.layerTile(layerName: "landcover", features: []))
        for layer in layers {
            let parsed = try parser.parse(tile: Self.coarseTile,
                                          mvtData: VectorTileFixture.layerTile(layerName: layer.name,
                                                                               features: layer.features))
            assertCounterClockwise(parsed.drawingPolygon, "\(layer.name) ground")
            assertCounterClockwise(parsed.drawingBridgePolygon, "\(layer.name) bridge overlay")
            XCTAssertGreaterThan(parsed.drawingPolygon.indices.count, backgroundOnly.drawingPolygon.indices.count,
                                 "\(layer.name): more than the background alone, so the features were emitted")
        }
    }

    func testStreetTileRoadGeometryIsCounterClockwise() throws {
        let parser = makeParser()
        let features: [VectorTileFixture.Feature] = [
            // A one-way avenue with a bend: ribbon, kerbs, unclipped joins
            // and the direction arrows.
            .road(id: 1, points: [(0, 1200), (1800, 1200), (2600, 1900), (4096, 1900)],
                  name: "Avenue", extra: ["oneway": "true"]),
            .road(id: 2, kind: "path", kindDetail: "footway", points: [(2048, 1052), (2048, 1352)]),
            .road(id: 7, kind: "minor_road", kindDetail: "service", points: [(200, 600), (3900, 600)],
                  extra: ["is_tunnel": "true"]),
            .road(id: 8, points: [(200, 300), (4300, 300)], extra: ["is_bridge": "true", "layer": "1"])
        ]
        let parsed = try parser.parse(tile: Self.streetTile,
                                      mvtData: VectorTileFixture.layerTile(layerName: "roads",
                                                                           features: features))
        assertCounterClockwise(parsed.drawingPolygon, "ground")
        assertCounterClockwise(parsed.drawingBridgePolygon, "bridge overlay")
        for structureKind in RoadStructureKind.allCases {
            let bucket = parsed.drawingRoadPhases.bucket(for: structureKind)
            for role in RoadPassRole.allCases {
                assertCounterClockwise(bucket.layer(for: role).drawing, "\(structureKind) \(role)")
            }
        }
        XCTAssertGreaterThan(parsed.drawingRoadPhases.bucket(for: .bridge).layer(for: .fill).drawing.indices.count, 0,
                             "The bridge bucket was exercised")
        XCTAssertGreaterThan(parsed.drawingRoadPhases.bucket(for: .tunnel).layer(for: .fill).drawing.indices.count, 0,
                             "The tunnel bucket was exercised")
    }
}
