// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The analytic line-antialiasing contract between `ParseLine` and the tile
/// shader: line geometry is extruded past the styled half-width by the
/// feather, every vertex carries a normalized signed centerline distance plus
/// a longitudinal end distance, and the styled edge is encoded as the
/// threshold byte. Plain polygons keep a zero threshold, which is what tells
/// the shader to leave them alone.
final class ParseLineAnalyticAntialiasingTests: XCTestCase {
    private let tileExtent: Float = 4096

    private func parseLine(points: [SIMD2<Float>],
                           width: Double,
                           startCapRound: Bool = false,
                           endCapRound: Bool = false,
                           lineJoinRound: Bool = false,
                           featherStart: Bool = false,
                           featherEnd: Bool = false,
                           clipGeometryToTileBounds: Bool = true) -> TileMvtParser.ParsedPolygon? {
        ParseLine().parse(points: points,
                          width: width,
                          tileExtent: tileExtent,
                          startCapRound: startCapRound,
                          endCapRound: endCapRound,
                          lineJoinRound: lineJoinRound,
                          featherStart: featherStart,
                          featherEnd: featherEnd,
                          clipGeometryToTileBounds: clipGeometryToTileBounds)
    }

    func testVertexLayoutMatchesThePipelineContract() {
        // TilePipeline's vertex descriptor and the arena image format both
        // hard-code these offsets; a layout drift is a rendering bug.
        XCTAssertEqual(MemoryLayout<TileVertexIn>.stride, 8)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.position), 0)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.styleIndex), 4)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.lineEdgeThreshold), 5)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.lineDistance), 6)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.lineEndDistance), 7)
    }

    func testStraightSegmentIsExtrudedByTheFeatherAndCarriesTheRimDistances() throws {
        let width = 10.0
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(100, 100), SIMD2(200, 100)], width: width))

        XCTAssertEqual(polygon.vertices.count, 4)
        XCTAssertEqual(polygon.lineDistances.count, polygon.vertices.count)
        XCTAssertEqual(polygon.lineEndDistances.count, polygon.vertices.count)

        // A horizontal line extrudes vertically: the quad spans the extruded
        // width (styled half-width plus feather on each side), not the styled
        // width.
        let extrudedHalfWidth = Float(width) * 0.5 + ParseLine.featherTileUnits
        let ys = Set(polygon.vertices.map(\.y))
        XCTAssertEqual(ys.count, 2)
        let flippedCenterY = tileExtent - 100
        XCTAssertEqual(Float(ys.max()!), flippedCenterY + extrudedHalfWidth, accuracy: 0.501)
        XCTAssertEqual(Float(ys.min()!), flippedCenterY - extrudedHalfWidth, accuracy: 0.501)

        // Every quad vertex sits on the extruded rim, one side positive, the
        // other negative; without the feather flags the ends stay hard, so
        // the longitudinal field is saturated everywhere.
        XCTAssertTrue(polygon.lineDistances.allSatisfy { abs(Int($0)) == Int(Int8.max) })
        XCTAssertEqual(Set(polygon.lineDistances).count, 2)
        XCTAssertTrue(polygon.lineEndDistances.allSatisfy { $0 == Int8.max })

        // The styled edge is the styled-over-extruded fraction of the field.
        let expectedThreshold = UInt8((Float(width) * 0.5 / extrudedHalfWidth * 255).rounded())
        XCTAssertEqual(polygon.lineEdgeThreshold, expectedThreshold)
    }

    func testFreeButtEndsGetALongitudinalRamp() throws {
        let width = 6.0
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(100, 100), SIMD2(200, 100)],
                                              width: width,
                                              featherStart: true,
                                              featherEnd: true))

        // Two ramp rows per feathered end: tip, ring, ring, tip.
        XCTAssertEqual(polygon.vertices.count, 8)
        XCTAssertEqual(polygon.lineEndDistances.count, polygon.vertices.count)

        // The tips extend one feather past the styled cuts, so the ramp's
        // zero isoline (the visible end) lands exactly on the endpoints.
        let feather = ParseLine.featherTileUnits
        let xs = polygon.vertices.map { Float($0.x) }
        XCTAssertEqual(xs.min()!, 100 - feather, accuracy: 0.501)
        XCTAssertEqual(xs.max()!, 200 + feather, accuracy: 0.501)

        // Tips carry the negative extreme, rings the positive one, and the
        // ramp crosses zero at the styled cut.
        XCTAssertEqual(polygon.lineEndDistances.filter { $0 == -Int8.max }.count, 4)
        XCTAssertEqual(polygon.lineEndDistances.filter { $0 == Int8.max }.count, 4)
        // The transverse field is untouched by the end rows.
        XCTAssertTrue(polygon.lineDistances.allSatisfy { abs(Int($0)) == Int(Int8.max) })
    }

    func testRoundCapWinsOverTheEndFeather() throws {
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(500, 500), SIMD2(600, 500)],
                                              width: 8,
                                              startCapRound: true,
                                              endCapRound: true,
                                              featherStart: true,
                                              featherEnd: true))

        // Capped ends must not also ramp longitudinally: the caps' radial
        // field owns the end, so the longitudinal field stays saturated.
        XCTAssertTrue(polygon.lineEndDistances.allSatisfy { $0 == Int8.max })
        // Two cap centers on the centerline, everything else on the rim.
        let centerCount = polygon.lineDistances.filter { $0 == 0 }.count
        XCTAssertEqual(centerCount, 2)
        XCTAssertTrue(polygon.lineDistances.allSatisfy { $0 == 0 || abs(Int($0)) == Int(Int8.max) })
    }

    func testRoundJoinTriangleInterpolatesFromCenterToRim() throws {
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(500, 500), SIMD2(600, 500), SIMD2(600, 600)],
                                              width: 8,
                                              lineJoinRound: true))

        XCTAssertEqual(polygon.lineDistances.count, polygon.vertices.count)
        XCTAssertEqual(polygon.lineEndDistances.count, polygon.vertices.count)
        // The join contributes its corner vertex on the centerline.
        XCTAssertTrue(polygon.lineDistances.contains(0))
    }

    func testClippingInterpolatesTheDistanceFieldAndStaysInsideTheTile() throws {
        // The quad of this line pokes out of the tile on the left; the clipped
        // result must stay inside while keeping the rim values of the cut, so
        // the antialiasing ramp is unbroken across the tile seam.
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(-50, 100), SIMD2(100, 100)],
                                              width: 10,
                                              featherEnd: true))

        XCTAssertFalse(polygon.vertices.isEmpty)
        XCTAssertEqual(polygon.lineDistances.count, polygon.vertices.count)
        XCTAssertEqual(polygon.lineEndDistances.count, polygon.vertices.count)
        XCTAssertTrue(polygon.vertices.allSatisfy { $0.x >= 0 && Float($0.x) <= tileExtent })
        // A longitudinal cut preserves the transverse field: both rims survive.
        XCTAssertEqual(polygon.lineDistances.max(), Int8.max)
        XCTAssertEqual(polygon.lineDistances.min(), -Int8.max)
        // The feathered inner end keeps its ramp extremes too.
        XCTAssertEqual(polygon.lineEndDistances.min(), -Int8.max)
        XCTAssertEqual(polygon.lineEndDistances.max(), Int8.max)
        XCTAssertNotEqual(polygon.lineEdgeThreshold, 0)
    }

    func testDiagonalClipInterpolatesIntermediateDistances() throws {
        // A diagonal line leaving the corner: the clip planes cut the quad at
        // an angle, so some intersection vertices must carry distances strictly
        // between the centerline and the rim.
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(-30, 60), SIMD2(120, -40)], width: 12))

        XCTAssertEqual(polygon.lineDistances.count, polygon.vertices.count)
        XCTAssertTrue(polygon.lineDistances.contains { abs(Int($0)) > 0 && abs(Int($0)) < Int(Int8.max) })
    }

    func testPlainPolygonGeometryKeepsAZeroThreshold() {
        let polygon = TileMvtParser.ParsedPolygon(vertices: [SIMD2<Int16>(0, 0)], indices: [0])
        XCTAssertEqual(polygon.lineEdgeThreshold, 0)
        XCTAssertTrue(polygon.lineDistances.isEmpty)
        XCTAssertTrue(polygon.lineEndDistances.isEmpty)
    }
}
