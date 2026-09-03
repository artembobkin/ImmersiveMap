// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The parser splits the ground of a coarse tile for the sphere and leaves a
/// street-zoom tile alone.
final class TileMvtParserSphereSubdivisionTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    func testCoarseTileGroundIsSplitOnTheGrid() throws {
        let parser = makeParser()
        let data = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["class": "ocean"])
        let coarse = try parser.parse(tile: Tile(x: 0, y: 0, z: 0), mvtData: data)
        let fine = try parser.parse(tile: Tile(x: 617, y: 320, z: 10), mvtData: data)
        XCTAssertGreaterThan(coarse.drawingPolygon.indices.count, fine.drawingPolygon.indices.count,
                             "The z0 ground carries the split, the z10 ground does not")
        let step = try XCTUnwrap(GroundGeometrySubdivider.step(forTileZoom: 0))
        let maximumEdge = Float(step) * Float(2).squareRoot() + 1
        let vertices = coarse.drawingPolygon.vertices
        let indices = Array(coarse.drawingPolygon.triangleIndices)
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            for edge in 0..<3 {
                let a = vertices[Int(indices[triangle + edge])].position
                let b = vertices[Int(indices[triangle + (edge + 1) % 3])].position
                let dx = Float(a.x) - Float(b.x)
                let dy = Float(a.y) - Float(b.y)
                XCTAssertLessThanOrEqual((dx * dx + dy * dy).squareRoot(), maximumEdge)
            }
        }
    }
}
