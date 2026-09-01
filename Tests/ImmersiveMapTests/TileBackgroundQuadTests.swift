// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The synthetic background every tile carries under its features is one
/// quad; the density the sphere needs comes from the ground subdivider, so
/// the background is exactly as fine as the rest of the ground at that
/// zoom and no finer: the 32x32 cells of z0, one quad from z10 where the
/// surface is flat.
final class TileBackgroundQuadTests: XCTestCase {
    private func parseBackgroundOnly(_ tile: Tile) throws -> TileMvtParser.DrawingPolygonBytes {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                                   labelProviderProfile: runtimeContext.labelProviderProfile,
                                   config: config,
                                   glyphCoverage: .legacyAtlasForTests)
        let parsed = try parser.parse(tile: tile,
                                      mvtData: VectorTileFixture.layerTile(layerName: "landcover", features: []))
        return parsed.drawingPolygon
    }

    func testTheBackgroundFollowsTheSubdividerGridByZoom() throws {
        let cellsPerSideByZoom: [(zoom: Int, cellsPerSide: Int)] = [
            (0, 32), (1, 32), (2, 16), (3, 16), (4, 8), (5, 8), (6, 4), (7, 4), (8, 2), (9, 2), (10, 1), (12, 1), (16, 1),
        ]
        for entry in cellsPerSideByZoom {
            let drawing = try parseBackgroundOnly(Tile(x: 0, y: 0, z: entry.zoom))
            let cells = entry.cellsPerSide
            XCTAssertEqual(drawing.indices.count, cells * cells * 2 * 3, "z\(entry.zoom): two triangles per grid cell")
            XCTAssertEqual(drawing.vertices.count, (cells + 1) * (cells + 1), "z\(entry.zoom): one vertex per grid corner")
        }
    }

    func testTheBackgroundSpansTheTileAndIsCounterClockwise() throws {
        for zoom in [0, 6, 12] {
            let drawing = try parseBackgroundOnly(Tile(x: 0, y: 0, z: zoom))
            let positions = drawing.vertices.map(\.position)
            XCTAssertEqual(positions.map(\.x).min(), 0, "z\(zoom)")
            XCTAssertEqual(positions.map(\.x).max(), 4096, "z\(zoom)")
            XCTAssertEqual(positions.map(\.y).min(), 0, "z\(zoom)")
            XCTAssertEqual(positions.map(\.y).max(), 4096, "z\(zoom)")
            XCTAssertNil(TileMvtParser.ParsedPolygon.firstClockwiseTriangle(vertices: positions, indices: drawing.indices),
                         "z\(zoom): every background triangle is counter-clockwise")
        }
    }
}
