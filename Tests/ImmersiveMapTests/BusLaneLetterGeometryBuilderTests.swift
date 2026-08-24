// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The letter A stamped along a bus lane: three quads per letter (two legs
/// sharing a mitered apex edge, the crossbar between their centrelines),
/// one letter per stretch of lane, and the apex of the letter points WITH
/// the direction of travel so the feet face the driver approaching it.
final class BusLaneLetterGeometryBuilderTests: XCTestCase {
    private let builder = BusLaneLetterGeometryBuilder()

    func testEachLegRingIsSimpleNotABowtie() {
        // The leg ring must run outer base, outer apex, inner apex, inner
        // base. A perpendicular taken raw points to opposite sides of the
        // two mirrored legs, and the first build folded one leg into a
        // bowtie: same four vertices, crossed ring, a wedge of the stroke
        // missing on the ground. Vertices alone cannot catch it, so this
        // asserts the ring is simple.
        let polygons = builder.buildPolygons(points: [SIMD2<Float>(1000, 500), SIMD2<Float>(1300, 500)],
                                             unitsPerMetre: 10)
        XCTAssertEqual(polygons.count, 3)
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>,
                   _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
            let r = b - a
            let s = d - c
            let denominator = r.x * s.y - r.y * s.x
            guard abs(denominator) > 1e-9 else { return false }
            let ac = c - a
            let t = (ac.x * s.y - ac.y * s.x) / denominator
            let u = (ac.x * r.y - ac.y * r.x) / denominator
            return t > 0 && t < 1 && u > 0 && u < 1
        }
        for legIndex in 0..<2 {
            let v = polygons[legIndex].vertices.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            XCTAssertEqual(v.count, 4)
            XCTAssertFalse(cross(v[0], v[1], v[2], v[3]),
                           "Leg \(legIndex): opposite ring edges cross, the quad is a bowtie")
            XCTAssertFalse(cross(v[1], v[2], v[3], v[0]),
                           "Leg \(legIndex): opposite ring edges cross, the quad is a bowtie")
        }
    }

    func testTheLegsShareTheApexEdgeAndNothingOvershoots() {
        // Ten units to the metre so quantization cannot blur the assertions.
        // A 30 m lane gets one letter at its middle, (1150, 3596) in render
        // space, apex toward +x.
        let polygons = builder.buildPolygons(points: [SIMD2<Float>(1000, 500), SIMD2<Float>(1300, 500)],
                                             unitsPerMetre: 10)
        XCTAssertEqual(polygons.count, 3)
        let legLeft = Set(polygons[0].vertices.map { [$0.x, $0.y] })
        let legRight = Set(polygons[1].vertices.map { [$0.x, $0.y] })
        XCTAssertEqual(legLeft.intersection(legRight).count, 2,
                       "The legs share exactly the two apex-edge vertices: one sharp point, no crossing butt caps")
        // Nothing sticks out of the letter's box: half height 13 plus the
        // mitered apex reach (halfStroke / sin(half spread), about 6 units
        // here) along the lane, half width 9 plus half a stroke across it.
        for polygon in polygons {
            for vertex in polygon.vertices {
                XCTAssertLessThanOrEqual(abs(Float(vertex.x) - 1150), 20,
                                         "vertex x=\(vertex.x) overshoots the letter along the lane")
                XCTAssertLessThanOrEqual(abs(Float(vertex.y) - 3596), 12,
                                         "vertex y=\(vertex.y) overshoots the letter across the lane")
            }
        }
        // The crossbar ends on the legs' centrelines, inside the spread.
        for vertex in polygons[2].vertices {
            XCTAssertLessThanOrEqual(abs(Float(vertex.y) - 3596), 9,
                                     "The crossbar stays between the legs")
        }
    }

    func testALetterIsThreeStrokesAndRepeatsAlongTheLane() {
        // One unit = one metre: a 95 m lane fits several letters 30 m apart.
        let polygons = builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(195, 500)],
                                             unitsPerMetre: 1)
        XCTAssertEqual(polygons.count % 3, 0, "A letter is two legs and the crossbar")
        XCTAssertEqual(polygons.count / 3, 3, "A 95 m lane carries a letter every ~30 m")
    }

    func testAShortStubGetsOneLetterAndATinyOneNone() {
        XCTAssertEqual(builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(120, 500)],
                                             unitsPerMetre: 1).count, 3,
                       "A short stub gets a single letter in its middle")
        XCTAssertTrue(builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(104, 500)],
                                            unitsPerMetre: 1).isEmpty,
                      "A stub shorter than the letter itself gets none")
    }

    func testTheApexPointsWithTheDirectionOfTravel() {
        // The lane runs toward +x in tile space; in render space (y flipped)
        // the tangent is still +x, so every letter vertex must sit within
        // the letter's height of the axis, and the apex (the vertex farthest
        // along x within one letter) lies AHEAD of the feet.
        let polygons = builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(130, 500)],
                                             unitsPerMetre: 1)
        XCTAssertEqual(polygons.count, 3)
        let vertices = polygons.flatMap(\.vertices)
        let minX = vertices.map(\.x).min() ?? 0
        let maxX = vertices.map(\.x).max() ?? 0
        XCTAssertEqual(Float(maxX - minX), 2.6, accuracy: 0.6, "The letter is about as tall as the lane is wide")
        // The crossbar stroke sits in the lower (feet) half of the letter.
        let crossbar = polygons[2]
        let crossbarX = crossbar.vertices.map { Float($0.x) }.reduce(0, +) / 4
        XCTAssertLessThan(crossbarX, Float(minX + maxX) / 2,
                          "The crossbar is nearer the feet, so the apex points with the travel direction")
    }
}
