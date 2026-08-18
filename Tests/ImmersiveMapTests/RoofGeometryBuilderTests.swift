// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Pins the invariants from the roof-rendering findings: the roof frame is a
/// property of the footprint (invariant under tile-grid rotation, steered by
/// `roof:orientation` / `roof:direction`), the mesh contains the vertices the
/// shape needs (ridge, apex), and the walls meet the roof watertightly.
final class RoofGeometryBuilderTests: XCTestCase {
    private let baseHeight: Float = 0
    private let topHeight: Float = 30
    private let roofHeight: Float = 10
    private var roofBase: Float { topHeight - roofHeight }

    /// A 100 x 40 rectangle whose long side runs along tile X.
    private let rectangle: [SIMD2<Float>] = [
        SIMD2(1000, 1000), SIMD2(1100, 1000), SIMD2(1100, 1040), SIMD2(1000, 1040)
    ]
    private let rectangleCenter = SIMD2<Float>(1050, 1020)

    private func makeRoof(_ shape: RoofShape,
                          orientation: RoofOrientation? = nil,
                          direction: Float? = nil) -> RoofInfo {
        RoofInfo(height: roofHeight, shape: shape, orientation: orientation, directionDegrees: direction)
    }

    private func build(_ shape: RoofShape,
                       ring: [SIMD2<Float>]? = nil,
                       orientation: RoofOrientation? = nil,
                       direction: Float? = nil) -> RoofGeometry? {
        RoofGeometryBuilder.build(roof: makeRoof(shape, orientation: orientation, direction: direction),
                                  exteriorRing: ring ?? rectangle,
                                  hasInteriorRings: false,
                                  flatTriangulationVertices: ring ?? rectangle,
                                  flatTriangulationIndices: [0, 1, 2, 0, 2, 3],
                                  baseHeight: baseHeight,
                                  topHeight: topHeight)
    }

    private func rotate(_ ring: [SIMD2<Float>], byDegrees degrees: Float, around pivot: SIMD2<Float>) -> [SIMD2<Float>] {
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return ring.map { point in
            let local = point - pivot
            return pivot + SIMD2<Float>(local.x * cosine - local.y * sine,
                                        local.x * sine + local.y * cosine)
        }
    }

    private func ridgeVertices(of geometry: RoofGeometry) -> [SIMD3<Float>] {
        geometry.surfaceVertices.map(\.position).filter { abs($0.z - topHeight) < 0.01 }
    }

    // MARK: - Gabled

    func testGabledRectangleRaisesARidgeAndKeepsCornersAtTheEaves() throws {
        let geometry = try XCTUnwrap(build(.gabled))

        let ridge = ridgeVertices(of: geometry)
        XCTAssertGreaterThanOrEqual(ridge.count, 2, "A gabled roof must contain ridge vertices at the full height")
        for vertex in ridge {
            XCTAssertEqual(vertex.y, 1020, accuracy: 0.01, "The ridge must run along the footprint's long axis")
        }
        let ridgeXs = ridge.map(\.x)
        XCTAssertEqual(try XCTUnwrap(ridgeXs.min()), 1000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(ridgeXs.max()), 1100, accuracy: 0.01)

        for corner in rectangle {
            XCTAssertEqual(geometry.wallTop(corner), roofBase, accuracy: 0.01,
                           "Rectangle corners sit at the eaves")
        }
    }

    func testGabledWallRingGainsRidgeCrossingsAtFullHeight() throws {
        let geometry = try XCTUnwrap(build(.gabled))

        XCTAssertEqual(geometry.wallExteriorRing.count, rectangle.count + 2,
                       "Each gable-end edge gains one ridge-crossing vertex")
        let inserted = geometry.wallExteriorRing.filter { ring in
            rectangle.contains(where: { simd_length($0 - ring) < 0.001 }) == false
        }
        XCTAssertEqual(inserted.count, 2)
        for crossing in inserted {
            XCTAssertEqual(crossing.y, 1020, accuracy: 0.01)
            XCTAssertEqual(geometry.wallTop(crossing), topHeight, accuracy: 0.01,
                           "The wall must rise to the ridge at a gable end, closing the triangle")
            XCTAssertTrue(geometry.surfaceVertices.contains { vertex in
                simd_length(SIMD2<Float>(vertex.position.x, vertex.position.y) - crossing) < 0.001
                    && abs(vertex.position.z - topHeight) < 0.01
            }, "The roof surface must own a vertex where the wall meets the ridge")
        }
    }

    func testGabledRoofIsInvariantUnderTileGridRotation() throws {
        let straight = try XCTUnwrap(build(.gabled))
        let degrees: Float = 30
        let rotatedRing = rotate(rectangle, byDegrees: degrees, around: rectangleCenter)
        let rotated = try XCTUnwrap(build(.gabled, ring: rotatedRing))

        let straightHeights = straight.surfaceVertices.map(\.position.z).sorted()
        let rotatedHeights = rotated.surfaceVertices.map(\.position.z).sorted()
        XCTAssertEqual(straightHeights.count, rotatedHeights.count)
        for (lhs, rhs) in zip(straightHeights, rotatedHeights) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.05,
                           "A rotated rectangle must get the same roof, rotated")
        }

        let ridge = ridgeVertices(of: rotated)
        let ridgeXY = ridge.map { SIMD2<Float>($0.x, $0.y) }
        let start = try XCTUnwrap(ridgeXY.min(by: { $0.x < $1.x }))
        let end = try XCTUnwrap(ridgeXY.max(by: { $0.x < $1.x }))
        let ridgeDirection = simd_normalize(end - start)
        let radians = degrees * .pi / 180
        let expected = SIMD2<Float>(cos(radians), sin(radians))
        XCTAssertEqual(abs(simd_dot(ridgeDirection, expected)), 1, accuracy: 0.001,
                       "The ridge must rotate with the footprint, not stay on the tile axes")
    }

    func testGabledAcrossOrientationTurnsTheRidge() throws {
        let geometry = try XCTUnwrap(build(.gabled, orientation: .across))
        let ridge = ridgeVertices(of: geometry)
        XCTAssertGreaterThanOrEqual(ridge.count, 2)
        for vertex in ridge {
            XCTAssertEqual(vertex.x, 1050, accuracy: 0.01,
                           "roof:orientation=across puts the ridge across the long axis")
        }
    }

    func testGabledDirectionOverridesTheFootprintAxis() throws {
        // Downslope east means the ridge runs north-south despite the long
        // axis running east-west.
        let geometry = try XCTUnwrap(build(.gabled, direction: 90))
        let ridge = ridgeVertices(of: geometry)
        XCTAssertGreaterThanOrEqual(ridge.count, 2)
        for vertex in ridge {
            XCTAssertEqual(vertex.x, 1050, accuracy: 0.01)
        }
    }

    func testGabledRoofNormalsPointUpward() throws {
        let geometry = try XCTUnwrap(build(.gabled))
        for vertex in geometry.surfaceVertices {
            XCTAssertGreaterThan(vertex.normal.z, 0, "Roof faces must be lit from above")
            XCTAssertEqual(simd_length(vertex.normal), 1, accuracy: 0.001)
        }
    }

    // MARK: - Hipped

    func testHippedRectangleKeepsLevelEavesAndInsetsTheRidge() throws {
        let geometry = try XCTUnwrap(build(.hipped))

        for vertex in geometry.surfaceVertices {
            let z = vertex.position.z
            XCTAssertTrue(abs(z - roofBase) < 0.01 || abs(z - topHeight) < 0.01,
                          "Hip faces run straight from the eaves to the ridge")
        }
        let ridge = ridgeVertices(of: geometry)
        XCTAssertGreaterThanOrEqual(ridge.count, 2)
        for vertex in ridge {
            XCTAssertEqual(vertex.y, 1020, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(vertex.x, 1020 - 0.01, "Hips pull the ridge in from the ends")
            XCTAssertLessThanOrEqual(vertex.x, 1080 + 0.01)
        }
        for corner in rectangle {
            XCTAssertEqual(geometry.wallTop(corner), roofBase, accuracy: 0.01,
                           "Hipped roofs have level eaves, so walls stop there")
        }
    }

    // MARK: - Pyramid, dome

    func testPyramidPutsTheApexAtTheCentroid() throws {
        let geometry = try XCTUnwrap(build(.pyramid))

        let apexes = ridgeVertices(of: geometry)
        XCTAssertFalse(apexes.isEmpty)
        for apex in apexes {
            XCTAssertEqual(apex.x, rectangleCenter.x, accuracy: 0.01)
            XCTAssertEqual(apex.y, rectangleCenter.y, accuracy: 0.01)
        }
        for vertex in geometry.surfaceVertices where abs(vertex.position.z - topHeight) > 0.01 {
            XCTAssertEqual(vertex.position.z, roofBase, accuracy: 0.01,
                           "Everything but the apex sits on the eaves ring")
        }
        for corner in rectangle {
            XCTAssertEqual(geometry.wallTop(corner), roofBase, accuracy: 0.01)
        }
    }

    func testPyramidApexIsInvariantUnderTileGridRotation() throws {
        let rotatedRing = rotate(rectangle, byDegrees: 30, around: rectangleCenter)
        let geometry = try XCTUnwrap(build(.pyramid, ring: rotatedRing))
        let apexes = ridgeVertices(of: geometry)
        XCTAssertFalse(apexes.isEmpty)
        for apex in apexes {
            XCTAssertEqual(apex.x, rectangleCenter.x, accuracy: 0.05)
            XCTAssertEqual(apex.y, rectangleCenter.y, accuracy: 0.05)
        }
    }

    func testDomeRisesFromTheEavesToAnApex() throws {
        let geometry = try XCTUnwrap(build(.dome))

        let heights = geometry.surfaceVertices.map(\.position.z)
        XCTAssertEqual(try XCTUnwrap(heights.max()), topHeight, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(heights.min()), roofBase, accuracy: 0.01)
        let distinctHeights = Set(heights.map { Int(($0 * 100).rounded()) })
        XCTAssertGreaterThan(distinctHeights.count, 3,
                             "A dome needs intermediate bands, not a flat lid")
        for vertex in geometry.surfaceVertices {
            XCTAssertGreaterThanOrEqual(vertex.normal.z, -0.001)
        }
        for corner in rectangle {
            XCTAssertEqual(geometry.wallTop(corner), roofBase, accuracy: 0.01)
        }
    }

    // MARK: - Skillion

    func testSkillionDescendsTowardItsDirection() throws {
        let geometry = try XCTUnwrap(build(.skillion, direction: 90))

        XCTAssertEqual(geometry.wallTop(SIMD2(1000, 1020)), topHeight, accuracy: 0.01,
                       "The west side is the high side when the roof faces east")
        XCTAssertEqual(geometry.wallTop(SIMD2(1100, 1020)), roofBase, accuracy: 0.01)

        let normals = geometry.surfaceVertices.map(\.normal)
        let first = try XCTUnwrap(normals.first)
        for normal in normals {
            XCTAssertEqual(simd_dot(normal, first), 1, accuracy: 0.001, "A skillion roof is one plane")
        }
        XCTAssertGreaterThan(first.x, 0, "The plane leans toward the downslope direction")
        XCTAssertGreaterThan(first.z, 0)
    }

    // MARK: - Fallbacks

    func testUnsupportedFootprintsFallBackToNil() {
        XCTAssertNil(RoofGeometryBuilder.build(roof: makeRoof(.gabled),
                                               exteriorRing: rectangle,
                                               hasInteriorRings: true,
                                               flatTriangulationVertices: rectangle,
                                               flatTriangulationIndices: [0, 1, 2, 0, 2, 3],
                                               baseHeight: baseHeight,
                                               topHeight: topHeight),
                     "A footprint with holes under a gabled roof falls back to the flat lid")
        XCTAssertNil(build(.flat))
        XCTAssertNil(RoofGeometryBuilder.build(roof: RoofInfo(height: 0, shape: .gabled, orientation: nil, directionDegrees: nil),
                                               exteriorRing: rectangle,
                                               hasInteriorRings: false,
                                               flatTriangulationVertices: rectangle,
                                               flatTriangulationIndices: [0, 1, 2, 0, 2, 3],
                                               baseHeight: baseHeight,
                                               topHeight: topHeight))
    }
}
