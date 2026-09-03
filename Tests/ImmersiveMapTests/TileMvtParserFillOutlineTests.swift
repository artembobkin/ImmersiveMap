// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The parser's ground bucket ends with the fill-outline segment: the ring
/// edges of every plain fill, as index pairs over the fill's own vertices,
/// after the fills and the line ribbons. Styles that are not plain fills
/// (a border drawn as a line) add nothing to it.
final class TileMvtParserFillOutlineTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    private static let lake: [(Int32, Int32)] = [(1000, 1000), (2000, 1000), (2000, 2000), (1000, 2000)]

    func testGroundBucketEndsWithTheFillOutlinePairs() throws {
        let data = VectorTileFixture.layerTile(
            layerName: "water",
            features: [.init(id: 1, geometry: .polygon(ring: Self.lake), properties: ["class": "lake"])]
        )
        let parsed = try makeParser().parse(tile: Tile(x: 617, y: 320, z: 10), mvtData: data)
        let drawing = parsed.drawingPolygon
        let outlinesStart = try XCTUnwrap(drawing.fillOutlinesIndexStart)
        let fillsCount = try XCTUnwrap(drawing.fillsIndexCount)
        XCTAssertLessThanOrEqual(fillsCount, outlinesStart)
        XCTAssertLessThan(outlinesStart, drawing.indices.count, "The lake's edges make an outline segment")
        XCTAssertEqual((drawing.indices.count - outlinesStart) % 2, 0, "Outlines are index pairs")
        XCTAssertEqual(drawing.indices.count - outlinesStart, 8, "Four edges of the lake")
        // Every pair names two fill vertices of one style, and the segment
        // adds no vertices of its own.
        let fillVertexCount = drawing.vertices.count
        for index in drawing.indices[outlinesStart...] {
            XCTAssertLessThan(Int(index), fillVertexCount)
        }
        // The runs the drawer reads mark the segment as the outline class.
        let ground = PreparedTileCPU.GeometryLayer(vertices: drawing.vertices,
                                                   indices: drawing.indices,
                                                   styles: parsed.styles,
                                                   overviewStyleMasks: parsed.overviewStyleMasks,
                                                   lineStyles: parsed.lineStyles,
                                                   fillsIndexCount: fillsCount,
                                                   fillOutlinesIndexStart: outlinesStart)
        let runs = GroundStyleRunScanner.scan(ground: ground)
        let outlineRuns = runs.filter(\.isFillOutlineClass)
        XCTAssertEqual(outlineRuns.count, 1)
        XCTAssertEqual(outlineRuns.first?.indexStart, UInt32(outlinesStart))
        XCTAssertEqual(outlineRuns.first?.indexCount, 8)
        XCTAssertTrue(outlineRuns.first?.isAlphaOpaque == true, "Water is an opaque fill")
    }

    /// A border is a line style: its ribbons carry the analytic line
    /// coverage already and produce no outline segment.
    func testLineStylesProduceNoOutline() throws {
        let data = VectorTileFixture.layerTile(
            layerName: "boundary",
            features: [.init(id: 1,
                             geometry: .line(points: [(0, 2048), (4096, 2048)]),
                             properties: ["admin_level": "2"])]
        )
        let parsed = try makeParser().parse(tile: Tile(x: 617, y: 320, z: 10), mvtData: data)
        let drawing = parsed.drawingPolygon
        XCTAssertEqual(drawing.fillOutlinesIndexStart, drawing.indices.count,
                       "The outline segment exists but is empty")
    }

    /// A coarse tile's ground is split on the sphere grid: the outline pairs
    /// survive the split and still name the ring's corner vertices.
    func testOutlineSurvivesTheSphereSubdivision() throws {
        let data = VectorTileFixture.layerTile(
            layerName: "water",
            features: [.init(id: 1, geometry: .polygon(ring: Self.lake), properties: ["class": "lake"])]
        )
        let parsed = try makeParser().parse(tile: Tile(x: 1, y: 1, z: 2), mvtData: data)
        let drawing = parsed.drawingPolygon
        let outlinesStart = try XCTUnwrap(drawing.fillOutlinesIndexStart)
        XCTAssertEqual(drawing.indices.count - outlinesStart, 8, "Still four edges: the outline is not split")
        let corners = Set(drawing.indices[outlinesStart...].map { drawing.vertices[Int($0)].position })
        XCTAssertEqual(corners, Set([SIMD2<Int16>(1000, 4096 - 1000), SIMD2<Int16>(2000, 4096 - 1000),
                                     SIMD2<Int16>(2000, 4096 - 2000), SIMD2<Int16>(1000, 4096 - 2000)]))
    }
}
