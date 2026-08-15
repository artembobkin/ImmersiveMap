// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The analytic line-antialiasing contract between `ParseLine` and the tile
/// shader: line geometry is extruded past the styled half-width by the
/// feather, every vertex carries a normalized signed centerline distance plus
/// a longitudinal parameter (end-feather distance for solid styles, arc
/// length for point-dashed ones). Where the styled edge sits, and whether a
/// style is a line at all, lives per style in `TileLineStyle`.
final class ParseLineAnalyticAntialiasingTests: XCTestCase {
    private let tileExtent: Float = 4096

    private func parseLine(points: [SIMD2<Float>],
                           width: Double,
                           startCapRound: Bool = false,
                           endCapRound: Bool = false,
                           lineJoinRound: Bool = false,
                           featherStart: Bool = false,
                           featherEnd: Bool = false,
                           emitsArcLength: Bool = false,
                           clipGeometryToTileBounds: Bool = true) -> TileMvtParser.ParsedPolygon? {
        ParseLine().parse(points: points,
                          width: width,
                          tileExtent: tileExtent,
                          startCapRound: startCapRound,
                          endCapRound: endCapRound,
                          lineJoinRound: lineJoinRound,
                          featherStart: featherStart,
                          featherEnd: featherEnd,
                          emitsArcLength: emitsArcLength,
                          clipGeometryToTileBounds: clipGeometryToTileBounds)
    }

    func testVertexLayoutMatchesThePipelineContract() {
        // TilePipeline's vertex descriptor and the arena image format both
        // hard-code these offsets; a layout drift is a rendering bug.
        XCTAssertEqual(MemoryLayout<TileVertexIn>.stride, 8)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.position), 0)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.styleIndex), 4)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.lineDistance), 5)
        XCTAssertEqual(MemoryLayout<TileVertexIn>.offset(of: \.lineParameter), 6)
        // The per-style line parameters are an arena span and a shader struct.
        XCTAssertEqual(MemoryLayout<TileLineStyle>.stride, 32)
    }

    func testStraightSegmentIsExtrudedByTheFeatherAndCarriesTheRimDistances() throws {
        let width = 10.0
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(100, 100), SIMD2(200, 100)], width: width))

        XCTAssertEqual(polygon.vertices.count, 4)
        XCTAssertEqual(polygon.lineDistances.count, polygon.vertices.count)
        XCTAssertEqual(polygon.lineParameters.count, polygon.vertices.count)

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
        // the longitudinal parameter is saturated everywhere.
        XCTAssertTrue(polygon.lineDistances.allSatisfy { abs(Int($0)) == Int(Int8.max) })
        XCTAssertEqual(Set(polygon.lineDistances).count, 2)
        XCTAssertTrue(polygon.lineParameters.allSatisfy { $0 == Int16.max })
    }

    func testFreeButtEndsGetALongitudinalRamp() throws {
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(100, 100), SIMD2(200, 100)],
                                              width: 6,
                                              featherStart: true,
                                              featherEnd: true))

        // Two ramp rows per feathered end: tip, ring, ring, tip.
        XCTAssertEqual(polygon.vertices.count, 8)
        XCTAssertEqual(polygon.lineParameters.count, polygon.vertices.count)

        // The tips extend one feather past the styled cuts, so the ramp's
        // zero isoline (the visible end) lands exactly on the endpoints.
        let feather = ParseLine.featherTileUnits
        let xs = polygon.vertices.map { Float($0.x) }
        XCTAssertEqual(xs.min()!, 100 - feather, accuracy: 0.501)
        XCTAssertEqual(xs.max()!, 200 + feather, accuracy: 0.501)

        // Tips carry the negative extreme, rings the positive one, and the
        // ramp crosses zero at the styled cut.
        XCTAssertEqual(polygon.lineParameters.filter { $0 == -Int16.max }.count, 4)
        XCTAssertEqual(polygon.lineParameters.filter { $0 == Int16.max }.count, 4)
        // The transverse field is untouched by the end rows.
        XCTAssertTrue(polygon.lineDistances.allSatisfy { abs(Int($0)) == Int(Int8.max) })
    }

    func testArcLengthModeAccumulatesAlongThePolylineInHalfUnits() throws {
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(100, 100), SIMD2(200, 100), SIMD2(200, 250)],
                                              width: 6,
                                              featherStart: true,
                                              featherEnd: true,
                                              emitsArcLength: true))

        // Arc mode ignores the feather flags: two plain rows per segment.
        XCTAssertEqual(polygon.vertices.count, 8)
        // Arc values in half tile units: 0 and 100 on the first segment, 100
        // and 250 on the second, each shared by the row's two rim vertices.
        XCTAssertEqual(polygon.lineParameters, [0, 0, 200, 200, 200, 200, 500, 500])
        XCTAssertTrue(polygon.lineDistances.allSatisfy { abs(Int($0)) == Int(Int8.max) })
    }

    func testArcSurvivesClippingByInterpolation() throws {
        // The line starts outside the tile; the clipped geometry must carry
        // interpolated arc values so the dash phase is continuous across the
        // cut instead of restarting.
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(-50, 100), SIMD2(150, 100)],
                                              width: 10,
                                              emitsArcLength: true))

        XCTAssertFalse(polygon.vertices.isEmpty)
        XCTAssertEqual(polygon.lineParameters.count, polygon.vertices.count)
        XCTAssertTrue(polygon.vertices.allSatisfy { $0.x >= 0 && Float($0.x) <= tileExtent })
        // At the tile edge (x = 0) the arc is 50 units into the line; at the
        // far end it is 200. Half-unit fixed point doubles both.
        XCTAssertLessThanOrEqual(abs(Int(polygon.lineParameters.min()!) - 100), 3)
        XCTAssertLessThanOrEqual(abs(Int(polygon.lineParameters.max()!) - 400), 3)
    }

    func testRoundCapWinsOverTheEndFeather() throws {
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(500, 500), SIMD2(600, 500)],
                                              width: 8,
                                              startCapRound: true,
                                              endCapRound: true,
                                              featherStart: true,
                                              featherEnd: true))

        // Capped ends must not also ramp longitudinally: the caps' radial
        // field owns the end, so the longitudinal parameter stays saturated.
        XCTAssertTrue(polygon.lineParameters.allSatisfy { $0 == Int16.max })
        // Two cap centers on the centerline, everything else on the rim.
        let centerCount = polygon.lineDistances.filter { $0 == 0 }.count
        XCTAssertEqual(centerCount, 2)
        XCTAssertTrue(polygon.lineDistances.allSatisfy { $0 == 0 || abs(Int($0)) == Int(Int8.max) })
    }

    func testDiagonalClipInterpolatesIntermediateDistances() throws {
        // A diagonal line leaving the corner: the clip planes cut the quad at
        // an angle, so some intersection vertices must carry distances strictly
        // between the centerline and the rim.
        let polygon = try XCTUnwrap(parseLine(points: [SIMD2(-30, 60), SIMD2(120, -40)], width: 12))

        XCTAssertEqual(polygon.lineDistances.count, polygon.vertices.count)
        XCTAssertTrue(polygon.lineDistances.contains { abs(Int($0)) > 0 && abs(Int($0)) < Int(Int8.max) })
    }

    func testPlainPolygonGeometryHasNoLineAttributes() {
        let polygon = TileMvtParser.ParsedPolygon(vertices: [SIMD2<Int16>(0, 0)], indices: [0])
        XCTAssertTrue(polygon.lineDistances.isEmpty)
        XCTAssertTrue(polygon.lineParameters.isEmpty)
        // The vertex an attribute-less polygon produces saturates the
        // parameter, so decoration polygons sharing a line style read as line
        // interior.
        let vertex = TileVertexIn(position: SIMD2<Int16>(0, 0), styleIndex: 0)
        XCTAssertEqual(vertex.lineDistance, 0)
        XCTAssertEqual(vertex.lineParameter, Int16.max)
    }
}
