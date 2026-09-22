// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Earcut
import Foundation
import XCTest

/// Runs the port against the reference implementation's own fixture corpus,
/// copied from `test/fixtures` and `test/expected.json` of mapbox/earcut
/// v3.2.3 into `Fixtures/`. The check is the upstream one: at the identity
/// rotation the triangle count must match, and at every quarter-turn rotation
/// the area deviation must stay within the recorded bound (zero for a fixture
/// the corpus lists no error for). A count that matches on all fifty-nine
/// fixtures says the port takes the same decisions as the reference, not only
/// that it covers the same area.
final class EarcutFixtureTests: XCTestCase {
    private struct Expected: Decodable {
        let triangles: [String: Int]
        let errors: [String: Double]
        let errorsWithRotation: [String: Double]

        enum CodingKeys: String, CodingKey {
            case triangles
            case errors
            case errorsWithRotation = "errors-with-rotation"
        }
    }

    /// A fixture flattened into the layout `Earcut.tessellate` takes.
    private struct Fixture {
        var vertices: [Double]
        var holeIndices: [Int]
    }

    func testFixturesMatchTheReferenceImplementation() throws {
        let expected = try loadExpected()
        XCTAssertEqual(expected.triangles.count, 59)

        for (name, expectedTriangles) in expected.triangles.sorted(by: { $0.key < $1.key }) {
            for rotation in [0, 90, 180, 270] {
                let fixture = try loadFixture(named: name, rotatedBy: rotation)
                let triangles = Earcut.tessellate(data: fixture.vertices,
                                                  holeIndices: fixture.holeIndices,
                                                  dim: 2)
                let deviation = Earcut.deviation(data: fixture.vertices,
                                                 holeIndices: fixture.holeIndices,
                                                 dim: 2,
                                                 triangles: triangles)
                let bound = (rotation != 0 ? expected.errorsWithRotation[name] : nil)
                    ?? expected.errors[name]
                    ?? 0

                XCTAssertEqual(triangles.count % 3, 0, "\(name) rotated by \(rotation): partial triangle")
                let vertexCount = fixture.vertices.count / 2
                for index in triangles where Int(index) >= vertexCount {
                    XCTFail("\(name) rotated by \(rotation): index \(index) past \(vertexCount) vertices")
                }
                if rotation == 0 {
                    XCTAssertEqual(triangles.count / 3, expectedTriangles,
                                   "\(name): \(triangles.count / 3) triangles, the reference makes \(expectedTriangles)")
                }
                if expectedTriangles > 0 {
                    XCTAssertLessThanOrEqual(deviation, bound,
                                             "\(name) rotated by \(rotation): deviation \(deviation) above \(bound)")
                }
            }
        }
    }

    /// The reference suite's guard against a hang on a degenerate hole.
    func testDegenerateHoleTerminates() {
        let data: [Double] = [1, 2, 2, 2, 1, 2, 1, 1, 1, 2, 4, 1, 5, 1, 3, 2, 4, 2, 4, 1]
        _ = Earcut.tessellate(data: data, holeIndices: [5], dim: 2)
    }

    /// The reference suite's regression for the hole-bridge block index: an
    /// outer ring on an integer grid, one collinear vertex per unit like MVT
    /// data, plus holes. Healing a collinear run across a block boundary used
    /// to leave the surviving edge outside its block's box, so the leftward
    /// ray scan skipped it and dropped a hole. Every rotation must cover the
    /// full area.
    func testCollinearOuterRingKeepsEveryHole() {
        let size = 30
        var outer: [[Double]] = []
        for x in 0...size { outer.append([Double(x), 0]) }
        for y in 1...size { outer.append([Double(size), Double(y)]) }
        for x in stride(from: size - 1, through: 0, by: -1) { outer.append([Double(x), Double(size)]) }
        for y in stride(from: size - 1, through: 1, by: -1) { outer.append([0, Double(y)]) }
        func rect(_ x0: Double, _ y0: Double, _ w: Double, _ h: Double) -> [[Double]] {
            [[x0, y0], [x0, y0 + h], [x0 + w, y0 + h], [x0 + w, y0]]
        }
        let rings = [outer, rect(5, 5, 2, 4), rect(2, 23, 1, 1)]

        for rotation in [0, 90, 180, 270] {
            let fixture = flatten(rings: rotate(rings: rings, by: rotation))
            let triangles = Earcut.tessellate(data: fixture.vertices,
                                              holeIndices: fixture.holeIndices,
                                              dim: 2)
            let deviation = Earcut.deviation(data: fixture.vertices,
                                             holeIndices: fixture.holeIndices,
                                             dim: 2,
                                             triangles: triangles)
            XCTAssertLessThan(deviation, 1e-9, "rotated by \(rotation): deviation \(deviation), a hole was dropped")
        }
    }

    // MARK: - Fixture loading

    private func fixturesDirectory() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil),
                      "the Fixtures directory is not in the test bundle")
    }

    private func loadExpected() throws -> Expected {
        let url = try fixturesDirectory().appendingPathComponent("expected.json")
        return try JSONDecoder().decode(Expected.self, from: Data(contentsOf: url))
    }

    private func loadFixture(named name: String, rotatedBy rotation: Int) throws -> Fixture {
        let url = try fixturesDirectory().appendingPathComponent("\(name).json")
        let rings = try JSONDecoder().decode([[[Double]]].self, from: Data(contentsOf: url))
        return flatten(rings: rotate(rings: rings, by: rotation))
    }

    /// Quarter-turn rotation with the integer-rounded matrix the reference
    /// suite uses, so the rotated coordinates stay exact.
    private func rotate(rings: [[[Double]]], by degrees: Int) -> [[[Double]]] {
        guard degrees != 0 else { return rings }
        let theta = Double(degrees) * Double.pi / 180
        let xx = cos(theta).rounded(), xy = (-sin(theta)).rounded()
        let yx = sin(theta).rounded(), yy = cos(theta).rounded()
        return rings.map { ring in
            ring.map { point in
                [xx * point[0] + xy * point[1], yx * point[0] + yy * point[1]]
            }
        }
    }

    /// The reference implementation's `flatten`: rings back to back, the
    /// vertex index at which each hole starts.
    private func flatten(rings: [[[Double]]]) -> Fixture {
        var fixture = Fixture(vertices: [], holeIndices: [])
        var vertexCount = 0
        for (ringNumber, ring) in rings.enumerated() {
            if ringNumber > 0 {
                fixture.holeIndices.append(vertexCount)
            }
            for point in ring {
                fixture.vertices.append(point[0])
                fixture.vertices.append(point[1])
            }
            vertexCount += ring.count
        }
        return fixture
    }
}
