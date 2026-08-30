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
/// round joins and caps, the background grid, the debug borders) and on a
/// street tile (ribbons, kerbs, junction and parking surfaces, one-way
/// arrows, crossing stripes, bus lane letters and the stop zigzag).
final class TileGeometryWindingTests: XCTestCase {
    private static let coarseTile = WebMercatorTileScheme.tile(latitude: 55.75, longitude: 37.61, z: 6)
    private static let streetTile = Tile(x: 39615, y: 20486, z: 16)

    private func makeParser(addTestBorders: Bool = false) -> TileMvtParser {
        var config = ImmersiveMapSettings.default
        config.tiles.parsing.addTestBorders = addTestBorders
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    private func assertCounterClockwise(_ drawing: TileMvtParser.DrawingPolygonBytes,
                                        _ name: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        let positions = drawing.vertices.map(\.position)
        if let triangle = TileMvtParser.ParsedPolygon.firstClockwiseTriangle(vertices: positions,
                                                                             indices: drawing.indices) {
            XCTFail("\(name): triangle \(triangle) of \(drawing.indices.count / 3) is clockwise",
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
        let holes: [[(Int32, Int32)]] = (0..<TileMvtParser.complexOceanHoleSplitThreshold).map { index in
            Array(Self.square(200 + Int32(index % 8) * 450, 200 + Int32(index / 8) * 450, 200).reversed())
        }
        let layers: [(name: String, features: [VectorTileFixture.Feature])] = [
            ("ocean", [.init(id: 1,
                             geometry: .polygonWithHoles(exterior: Self.square(0, 0, 4096), interiors: holes),
                             properties: ["class": "ocean"])]),
            ("water", [.init(id: 1,
                             geometry: .polygonWithHoles(exterior: Self.square(100, 100, 3000),
                                                         interiors: [Array(Self.square(1000, 1000, 800).reversed())]),
                             properties: ["class": "ocean"])]),
            ("landcover", [.init(id: 1,
                                 geometry: .polygon(ring: Self.square(300, 300, 1500)),
                                 properties: ["class": "wood"]),
                           .init(id: 2,
                                 geometry: .polygon(ring: [(2000, 2000), (3800, 2000), (3800, 3800),
                                                           (2900, 2600), (2000, 3800)]),
                                 properties: ["class": "grass"])]),
            // The overview stroke with round joins and caps: a right and a
            // left turn inside the tile, a bend leaving the tile (the clip
            // re-fans it), and a bridge.
            ("transportation", [.init(id: 1,
                                      geometry: .line(points: [(300, 3000), (1200, 3000), (1200, 3600), (2000, 3600)]),
                                      properties: ["class": "primary"]),
                                .init(id: 2,
                                      geometry: .line(points: [(2500, 500), (3500, 500), (3500, 1500), (4500, 1500)]),
                                      properties: ["class": "primary"]),
                                .init(id: 3,
                                      geometry: .line(points: [(500, 800), (1500, 1200)]),
                                      properties: ["class": "primary", "brunnel": "bridge"])])
        ]
        for layer in layers {
            let parsed = try parser.parse(tile: Self.coarseTile,
                                          mvtData: VectorTileFixture.layerTile(layerName: layer.name,
                                                                               features: layer.features))
            assertCounterClockwise(parsed.drawingPolygon, "\(layer.name) ground")
            assertCounterClockwise(parsed.drawingBridgePolygon, "\(layer.name) bridge overlay")
            XCTAssertGreaterThan(parsed.drawingPolygon.indices.count, 64 * 64 * 2 * 3,
                                 "\(layer.name): more than the background grid, so the features were emitted")
        }
    }

    func testStreetTileRoadGeometryIsCounterClockwise() throws {
        let parser = makeParser()
        let features: [VectorTileFixture.Feature] = [
            // A one-way avenue with a bend: ribbon, kerbs, unclipped joins
            // and the direction arrows.
            .init(id: 1,
                  geometry: .line(points: [(0, 1200), (1800, 1200), (2600, 1900), (4096, 1900)]),
                  properties: ["class": "primary", "lanes": "4", "oneway": "1", "name": "Avenue"]),
            .init(id: 2,
                  geometry: .line(points: [(2048, 1052), (2048, 1352)]),
                  properties: ["class": "path", "subclass": "footway", "crossing": "marked"]),
            .init(id: 3,
                  geometry: .polygon(ring: Self.square(1500, 2400, 1200)),
                  properties: ["subclass": "parking_area"]),
            .init(id: 4,
                  geometry: .polygon(ring: Self.square(3000, 2400, 600)),
                  properties: ["class": "primary", "subclass": "junction_area", "origin": "graph"]),
            .init(id: 5,
                  geometry: .line(points: [(500, 3300), (3600, 3300)]),
                  properties: ["marking": "bus_lane"]),
            .init(id: 6,
                  geometry: .line(points: [(500, 3600), (2500, 3600)]),
                  properties: ["marking": "bus_stop_zigzag"]),
            .init(id: 7,
                  geometry: .line(points: [(200, 600), (3900, 600)]),
                  properties: ["class": "service", "brunnel": "tunnel"]),
            .init(id: 8,
                  geometry: .line(points: [(200, 300), (4300, 300)]),
                  properties: ["class": "primary", "lanes": "4", "brunnel": "bridge", "layer": "1"])
        ]
        let parsed = try parser.parse(tile: Self.streetTile,
                                      mvtData: VectorTileFixture.layerTile(layerName: "transportation",
                                                                           features: features))
        assertCounterClockwise(parsed.drawingPolygon, "ground")
        assertCounterClockwise(parsed.drawingBridgePolygon, "bridge overlay")
        for structureKind in TileMvtParser.RoadStructureKind.allCases {
            let bucket = parsed.drawingRoadPhases.bucket(for: structureKind)
            for role in RoadPassRole.allCases {
                assertCounterClockwise(bucket.layer(for: role).drawing, "\(structureKind) \(role)")
            }
        }
        XCTAssertGreaterThan(parsed.drawingRoadPhases.bucket(for: .automobileGround).layer(for: .detail).drawing.indices.count, 0,
                             "The decorations (arrows, stripes, letters, zigzag) were emitted")
        XCTAssertGreaterThan(parsed.drawingRoadPhases.bucket(for: .bridge).layer(for: .fill).drawing.indices.count, 0,
                             "The bridge bucket was exercised")
        XCTAssertGreaterThan(parsed.drawingRoadPhases.bucket(for: .tunnel).layer(for: .fill).drawing.indices.count, 0,
                             "The tunnel bucket was exercised")
    }
}
