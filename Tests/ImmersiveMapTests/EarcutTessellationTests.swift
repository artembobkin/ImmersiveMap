// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Validates the internal earcut port. The canonical invariant, taken from the
/// reference implementation's own test suite, is area deviation: the summed
/// area of the produced triangles must match the polygon area (holes
/// subtracted) almost exactly.
final class EarcutTessellationTests: XCTestCase {
    func testSquareProducesTwoTriangles() {
        let data: [Double] = [0, 0, 10, 0, 10, 10, 0, 10]
        let triangles = Earcut.tessellate(data: data)

        XCTAssertEqual(triangles.count, 6)
        assertValidTriangulation(data: data, holeIndices: [], triangles: triangles)
    }

    func testConcavePolygon() {
        let data: [Double] = [0, 0, 9, 0, 6, 8, 5, 3, 2, 8, 0, 8]
        let triangles = Earcut.tessellate(data: data)

        XCTAssertEqual(triangles.count % 3, 0)
        XCTAssertGreaterThanOrEqual(triangles.count / 3, 4)
        assertValidTriangulation(data: data, holeIndices: [], triangles: triangles)
    }

    func testThreeDimensionalInputIgnoresZ() {
        // Same polygon twice: flat 2D coordinates, and 3D coordinates with
        // arbitrary non-zero z components. The triangulations must be
        // identical because z is ignored entirely.
        let flat: [Double] = [
            0, 0, 9, 0, 6, 8, 5, 3, 2, 8, 0, 8,
            6, 2, 7, 1, 7, 3, 6, 3, 5, 2, 6, 2
        ]
        var lifted: [Double] = []
        for vertexIndex in 0..<(flat.count / 2) {
            lifted.append(flat[vertexIndex * 2])
            lifted.append(flat[vertexIndex * 2 + 1])
            lifted.append(Double(vertexIndex) * 7.5 - 20.0)
        }

        let flatTriangles = Earcut.tessellate(data: flat, holeIndices: [6], dim: 2)
        let liftedTriangles = Earcut.tessellate(data: lifted, holeIndices: [6], dim: 3)

        XCTAssertFalse(flatTriangles.isEmpty)
        XCTAssertEqual(liftedTriangles, flatTriangles)
        XCTAssertLessThan(Earcut.deviation(data: lifted, holeIndices: [6], dim: 3, triangles: liftedTriangles), 1e-9)
    }

    func testPolygonWithHole() {
        let data: [Double] = [
            0, 0, 100, 0, 100, 100, 0, 100,
            30, 30, 70, 30, 70, 70, 30, 70
        ]
        let triangles = Earcut.tessellate(data: data, holeIndices: [4])

        XCTAssertFalse(triangles.isEmpty)
        assertValidTriangulation(data: data, holeIndices: [4], triangles: triangles)
    }

    func testPolygonWithSteinerPointHole() {
        let data: [Double] = [
            0, 0, 100, 0, 100, 100, 0, 100,
            50, 50
        ]
        let triangles = Earcut.tessellate(data: data, holeIndices: [4])

        XCTAssertFalse(triangles.isEmpty)
        assertValidTriangulation(data: data, holeIndices: [4], triangles: triangles)
    }

    func testDuplicateClosingPointRing() {
        let data: [Double] = [0, 0, 10, 0, 10, 10, 0, 10, 0, 0]
        let triangles = Earcut.tessellate(data: data)

        XCTAssertFalse(triangles.isEmpty)
        assertValidTriangulation(data: data, holeIndices: [], triangles: triangles)
    }

    func testCollinearRingProducesNothing() {
        let data: [Double] = [0, 0, 5, 0, 10, 0]
        XCTAssertTrue(Earcut.tessellate(data: data).isEmpty)
    }

    func testDegenerateInputs() {
        XCTAssertTrue(Earcut.tessellate(data: []).isEmpty)
        XCTAssertTrue(Earcut.tessellate(data: [0, 0]).isEmpty)
        XCTAssertTrue(Earcut.tessellate(data: [0, 0, 1, 1]).isEmpty)
    }

    /// More than 80 vertices switches the implementation to the z-order hashed
    /// ear checks; this shape also carries enough holes to exercise hole
    /// elimination together with that path.
    func testLargeJaggedRingWithManyHoles() {
        var generator = SplitMix64Generator(seed: 0xEAC0)
        var data: [Double] = []
        var holeIndices: [Int] = []

        // The jagged outer ring never dips below radius 1820 from the center,
        // and every hole stays within radius 1640, so all holes are strictly
        // inside and the area invariant holds exactly.
        let outerVertexCount = 220
        for vertexIndex in 0..<outerVertexCount {
            let angle = 2.0 * Double.pi * Double(vertexIndex) / Double(outerVertexCount)
            let radius = 2600.0 * (0.7 + 0.6 * generator.unitDouble())
            data.append(2048.0 + radius * cos(angle))
            data.append(2048.0 + radius * sin(angle))
        }

        // A 9x8 grid with 300 spacing: hole centers stay within radius 1595 of
        // the ring center and no two holes (radius <= 80) can touch.
        for holeNumber in 0..<70 {
            let column = Double(holeNumber % 9) - 4.0
            let row = Double(holeNumber / 9) - 3.5
            let centerX = 2048.0 + column * 300.0
            let centerY = 2048.0 + row * 300.0
            let radius = 20.0 + 60.0 * generator.unitDouble()
            let vertexCount = 6 + Int(generator.next() % 10)
            holeIndices.append(data.count / 2)
            for vertexIndex in 0..<vertexCount {
                // Reversed winding relative to the outer ring.
                let angle = -2.0 * Double.pi * Double(vertexIndex) / Double(vertexCount)
                data.append(centerX + radius * cos(angle))
                data.append(centerY + radius * sin(angle))
            }
        }

        let triangles = Earcut.tessellate(data: data, holeIndices: holeIndices)
        XCTAssertFalse(triangles.isEmpty)
        XCTAssertLessThan(Earcut.deviation(data: data, holeIndices: holeIndices, dim: 2, triangles: triangles), 1e-9)
        assertIndicesInRange(data: data, triangles: triangles)
    }

    func testFuzzedStarPolygonsWithHoles() {
        var generator = SplitMix64Generator(seed: 0xF022)

        for round in 0..<300 {
            var data: [Double] = []
            var holeIndices: [Int] = []

            // Star-shaped outer ring: strictly simple, never self-intersects.
            let outerVertexCount = 8 + Int(generator.next() % 120)
            let outerRadius = 500.0 + 3000.0 * generator.unitDouble()
            for vertexIndex in 0..<outerVertexCount {
                let angle = 2.0 * Double.pi * Double(vertexIndex) / Double(outerVertexCount)
                let radius = outerRadius * (0.55 + 0.45 * generator.unitDouble())
                data.append(5000.0 + radius * cos(angle))
                data.append(5000.0 + radius * sin(angle))
            }

            // Small non-overlapping holes on a grid well inside the star core.
            let holeCount = Int(generator.next() % 9)
            for holeNumber in 0..<holeCount {
                let cellX = Double(holeNumber % 3) - 1.0
                let cellY = Double(holeNumber / 3) - 1.0
                let centerX = 5000.0 + cellX * 120.0
                let centerY = 5000.0 + cellY * 120.0
                let radius = 15.0 + 35.0 * generator.unitDouble()
                let vertexCount = 3 + Int(generator.next() % 10)
                holeIndices.append(data.count / 2)
                for vertexIndex in 0..<vertexCount {
                    let angle = -2.0 * Double.pi * Double(vertexIndex) / Double(vertexCount)
                    data.append(centerX + radius * cos(angle))
                    data.append(centerY + radius * sin(angle))
                }
            }

            let triangles = Earcut.tessellate(data: data, holeIndices: holeIndices)
            XCTAssertFalse(triangles.isEmpty, "round \(round) produced no triangles")
            XCTAssertEqual(triangles.count % 3, 0, "round \(round) produced a partial triangle")
            assertIndicesInRange(data: data, triangles: triangles)

            let deviation = Earcut.deviation(data: data,
                                             holeIndices: holeIndices,
                                             dim: 2,
                                             triangles: triangles)
            XCTAssertLessThan(deviation, 1e-6, "round \(round) area deviation too large")
        }
    }

    // MARK: - Helpers

    private func assertValidTriangulation(data: [Double],
                                          holeIndices: [Int],
                                          triangles: [UInt32],
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        XCTAssertEqual(triangles.count % 3, 0, file: file, line: line)
        assertIndicesInRange(data: data, triangles: triangles, file: file, line: line)
        let deviation = Earcut.deviation(data: data,
                                         holeIndices: holeIndices,
                                         dim: 2,
                                         triangles: triangles)
        XCTAssertLessThan(deviation, 1e-9, file: file, line: line)
    }

    private func assertIndicesInRange(data: [Double],
                                      triangles: [UInt32],
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let vertexCount = data.count / 2
        for index in triangles {
            XCTAssertLessThan(Int(index), vertexCount, file: file, line: line)
        }
    }

}
