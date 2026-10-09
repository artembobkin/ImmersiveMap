// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The rounded building (`BuildingExtrusionMeshBuilder.buildRounded`): its
/// faces wound as the sharp walls are, closed but for its floor, its radius
/// held to what the building takes, and its edges at the tile's edge left
/// sharp.
final class BuildingRoundedExtrusionTests: XCTestCase {
    private static let square: [SIMD2<Float>] = [
        SIMD2(1000, 1000), SIMD2(1200, 1000), SIMD2(1200, 1200), SIMD2(1000, 1200)
    ]
    /// An L: five convex corners and one concave.
    private static let ell: [SIMD2<Float>] = [
        SIMD2(1000, 1000), SIMD2(1300, 1000), SIMD2(1300, 1100),
        SIMD2(1100, 1100), SIMD2(1100, 1300), SIMD2(1000, 1300)
    ]

    private func mesh(_ exterior: [SIMD2<Float>],
                      interiors: [[SIMD2<Float>]] = [],
                      top: Float = 80,
                      radius: Float) -> ParsedExtrudedMesh? {
        BuildingExtrusionMeshBuilder.build(clippedExterior: exterior,
                                           clippedInteriors: interiors,
                                           roof: ParsedPolygon(vertices: exterior, indices: [0, 1, 2, 0, 2, 3]),
                                           baseHeight: 0,
                                           topHeight: top,
                                           edgeRadius: radius,
                                           tileExtent: 4096)
    }

    func testNoRadiusIsTheSharpBox() throws {
        let sharp = try XCTUnwrap(mesh(Self.square, radius: 0))
        XCTAssertEqual(sharp.vertices.count, 4 + 16, "the lid and four walls")
        let tiny = try XCTUnwrap(mesh([SIMD2(1000, 1000), SIMD2(1002, 1000), SIMD2(1002, 1002), SIMD2(1000, 1002)],
                                      radius: 10))
        XCTAssertEqual(tiny.vertices.count, 4 + 16, "a building too small for any radius stays a box")
    }

    /// Every face of a convex rounded block faces away from its middle,
    /// with the winding of the sharp walls (`cross(c - a, b - a)` out).
    func testEveryFaceOfARoundedBlockFacesOut() throws {
        let rounded = try XCTUnwrap(mesh(Self.square, radius: 10))
        XCTAssertGreaterThan(rounded.vertices.count, 20, "the bevels add faces")
        let middle = SIMD3<Float>(1100, 1100, 40)
        for triangle in stride(from: 0, to: rounded.indices.count, by: 3) {
            let a = rounded.vertices[Int(rounded.indices[triangle])].position
            let b = rounded.vertices[Int(rounded.indices[triangle + 1])].position
            let c = rounded.vertices[Int(rounded.indices[triangle + 2])].position
            let facing = simd_cross(c - a, b - a)
            let centroid = (a + b + c) / 3
            XCTAssertGreaterThan(simd_dot(facing, centroid - middle), 0, "triangle \(triangle / 3) faces out")
        }
    }

    /// The surface is closed but for the floor: every edge joins two
    /// triangles, and the edges on the ground one.
    func testARoundedBuildingIsClosedButForItsFloor() throws {
        for (name, ring) in [("square", Self.square), ("ell", Self.ell)] {
            let rounded = try XCTUnwrap(mesh(ring, radius: 10))
            var uses: [EdgeKey: Int] = [:]
            for triangle in stride(from: 0, to: rounded.indices.count, by: 3) {
                let corners = (0 ..< 3).map { rounded.vertices[Int(rounded.indices[triangle + $0])].position }
                for side in 0 ..< 3 {
                    uses[EdgeKey(corners[side], corners[(side + 1) % 3]), default: 0] += 1
                }
            }
            for (edge, count) in uses {
                let onTheGround = edge.lower.z == 0 && edge.upper.z == 0
                XCTAssertEqual(count, onTheGround ? 1 : 2, "\(name): \(edge)")
            }
        }
    }

    /// The roof is drawn in by the radius, the walls stop under it, and the
    /// lid stays inside the footprint.
    func testTheRoofIsDrawnInByTheRadius() throws {
        let rounded = try XCTUnwrap(mesh(Self.square, radius: 10))
        let roof = rounded.vertices.filter { $0.position.z == 80 && $0.normal.z > 0.99 }
        XCTAssertFalse(roof.isEmpty)
        for vertex in roof {
            XCTAssertTrue((1009 ... 1191).contains(vertex.position.x) && (1009 ... 1191).contains(vertex.position.y),
                          "the rim is drawn in: \(vertex.position)")
        }
        let wallTops = rounded.vertices.filter { abs($0.normal.z) < 0.01 }.map(\.position.z).max()
        XCTAssertEqual(try XCTUnwrap(wallTops), 70, accuracy: 1e-3, "the walls stop a radius under the roof")
    }

    /// On the ground the building stands on its footprint: the bevels
    /// begin a radius over it, and the ground edges run corner to corner.
    func testTheBuildingStandsOnItsSharpFootprint() throws {
        let rounded = try XCTUnwrap(mesh(Self.square, radius: 10))
        let onTheGround = Set(rounded.vertices.filter { $0.position.z == 0 }.map { SIMD2($0.position.x, $0.position.y) })
        XCTAssertEqual(onTheGround, Set(Self.square), "only the footprint's corners touch the ground")
        let lowestOverTheGround = rounded.vertices.map(\.position.z).filter { $0 > 0 }.min()
        XCTAssertEqual(try XCTUnwrap(lowestOverTheGround), 10, accuracy: 1e-3, "the bevels begin a radius over the ground")
    }

    /// The radius is held under half the height and a quarter of the
    /// building's narrow side.
    func testTheRadiusIsHeldToTheBuilding() throws {
        let low = try XCTUnwrap(mesh(Self.square, top: 8, radius: 10))
        let lowWallTop = try XCTUnwrap(low.vertices.filter { abs($0.normal.z) < 0.01 }.map(\.position.z).max())
        XCTAssertEqual(lowWallTop, 8 - 8 * 0.45, accuracy: 1e-3)
        let narrow: [SIMD2<Float>] = [SIMD2(1000, 1000), SIMD2(1400, 1000), SIMD2(1400, 1010), SIMD2(1000, 1010)]
        let thin = try XCTUnwrap(mesh(narrow, radius: 10))
        let thinWallTop = try XCTUnwrap(thin.vertices.filter { abs($0.normal.z) < 0.01 }.map(\.position.z).max())
        XCTAssertGreaterThan(thinWallTop, 80 - 2.6, "a 10-unit-wide block takes a radius of about 2.5")
    }

    /// Where the footprint was clipped at the tile's edge no wall stands
    /// and nothing is rounded: the roof keeps the edge, where the next
    /// tile's building goes on.
    func testTheTileEdgeStaysSharp() throws {
        let clipped: [SIMD2<Float>] = [SIMD2(0, 1000), SIMD2(200, 1000), SIMD2(200, 1200), SIMD2(0, 1200)]
        let rounded = try XCTUnwrap(mesh(clipped, radius: 10))
        let rimOnTheEdge = Set(rounded.vertices
            .filter { $0.position.z == 80 && $0.normal.z > 0.99 && $0.position.x == 0 }
            .map(\.position))
        XCTAssertEqual(rimOnTheEdge, [SIMD3(0, 1000, 80), SIMD3(0, 1200, 80)],
                       "the roof's corners on the tile's edge stay on it")
        XCTAssertFalse(rounded.vertices.contains { abs($0.normal.x + 1) < 0.01 }, "no wall faces the tile's edge")
    }

    /// An edge by its two ends, in either order.
    private struct EdgeKey: Hashable, CustomStringConvertible {
        let lower: SIMD3<Float>
        let upper: SIMD3<Float>

        init(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            let aFirst = (a.x, a.y, a.z) < (b.x, b.y, b.z)
            lower = aFirst ? a : b
            upper = aFirst ? b : a
        }

        var description: String { "\(lower) - \(upper)" }
    }
}
