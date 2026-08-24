// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The yellow sawtooth at a public transport stop: teeth folded across the
/// shipped axis, anchored to it at both ends, never reaching farther than
/// the sawtooth's sweep, emitted as ONE mitered band so no joint can gap
/// or double-stamp whatever the corner angle.
final class BusStopZigzagGeometryBuilderTests: XCTestCase {
    private let builder = BusStopZigzagGeometryBuilder()

    func testTheSawtoothFoldsAcrossTheAxisAndStaysNearIt() {
        // One unit = one metre, an 18 m axis: one tooth vertex per 1.2 m.
        let polygons = builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(118, 500)],
                                             unitsPerMetre: 1)
        XCTAssertEqual(polygons.count, 1, "The sawtooth is one seamless band")
        let band = polygons[0]
        XCTAssertGreaterThanOrEqual(band.vertices.count, 24, "An 18 m stop folds a dozen tooth strokes")
        var sawAbove = false
        var sawBelow = false
        for vertex in band.vertices {
            // The builder is fed tile space (y = 500) and emits render
            // space vertices, hence the flipped axis to compare against.
            let acrossAxis = Float(vertex.y) - (4096 - 500)
            XCTAssertLessThanOrEqual(abs(acrossAxis), 1.2,
                                     "A tooth never reaches past the sawtooth's sweep")
            if acrossAxis > 0.3 { sawAbove = true }
            if acrossAxis < -0.3 { sawBelow = true }
        }
        XCTAssertTrue(sawAbove && sawBelow, "The teeth sway to both sides of the axis")
    }

    func testTheBandIsSeamlessAndEndsExactlyAtBothAxisEnds() {
        // Scaled ten units to the metre so quantization cannot blur the
        // geometry under test. 18 m of axis, teeth every 1.2 m: the step is
        // the length divided into whole half-periods, so the last tooth
        // stands exactly on the axis end and no tail is dropped.
        let polygons = builder.buildPolygons(points: [SIMD2<Float>(1000, 500), SIMD2<Float>(1180, 500)],
                                             unitsPerMetre: 10)
        XCTAssertEqual(polygons.count, 1)
        let band = polygons[0]
        let teethCount = band.vertices.count / 2
        XCTAssertEqual(band.vertices.count, teethCount * 2, "Two shared edge vertices per tooth")
        XCTAssertEqual(band.indices.count, (teethCount - 1) * 6,
                       "One quad per segment, sharing its joint vertices with the next")
        // The shared-vertex construction IS the seamlessness: each interior
        // vertex index appears in both neighbouring quads.
        for joint in 1..<(teethCount - 1) {
            let left = UInt32(joint * 2)
            let previousQuad = Array(band.indices[((joint - 1) * 6)..<(joint * 6)])
            let nextQuad = Array(band.indices[(joint * 6)..<((joint + 1) * 6)])
            XCTAssertTrue(previousQuad.contains(left) && nextQuad.contains(left),
                          "Joint \(joint) is shared between its two quads")
        }
        // Both band ends sit on the axis ends (render space y = 4096 - 500).
        let start = (SIMD2<Float>(Float(band.vertices[0].x), Float(band.vertices[0].y))
            + SIMD2<Float>(Float(band.vertices[1].x), Float(band.vertices[1].y))) * 0.5
        let last = band.vertices.count - 2
        let end = (SIMD2<Float>(Float(band.vertices[last].x), Float(band.vertices[last].y))
            + SIMD2<Float>(Float(band.vertices[last + 1].x), Float(band.vertices[last + 1].y))) * 0.5
        XCTAssertEqual(simd_distance(start, SIMD2<Float>(1000, 3596)), 0, accuracy: 1)
        XCTAssertEqual(simd_distance(end, SIMD2<Float>(1180, 3596)), 0, accuracy: 1)
    }

    func testAStubShorterThanOneToothGetsNothing() {
        XCTAssertTrue(builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(102, 500)],
                                            unitsPerMetre: 1).isEmpty)
    }
}
