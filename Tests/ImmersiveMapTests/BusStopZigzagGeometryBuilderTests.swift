// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The yellow sawtooth at a public transport stop: teeth folded across the
/// shipped axis, anchored to it at both ends, never reaching farther than
/// the sawtooth's sweep.
final class BusStopZigzagGeometryBuilderTests: XCTestCase {
    private let builder = BusStopZigzagGeometryBuilder()

    func testTheSawtoothFoldsAcrossTheAxisAndStaysNearIt() {
        // One unit = one metre, an 18 m axis: one tooth per 2.4 m.
        let polygons = builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(118, 500)],
                                             unitsPerMetre: 1)
        XCTAssertGreaterThanOrEqual(polygons.count, 12, "An 18 m stop folds a dozen tooth strokes")
        var sawAbove = false
        var sawBelow = false
        for polygon in polygons {
            for vertex in polygon.vertices {
                // The builder is fed tile space (y = 500) and emits render
                // space vertices, hence the flipped axis to compare against.
                let acrossAxis = Float(vertex.y) - (4096 - 500)
                XCTAssertLessThanOrEqual(abs(acrossAxis), 1.2,
                                         "A tooth never reaches past the sawtooth's sweep")
                if acrossAxis > 0.3 { sawAbove = true }
                if acrossAxis < -0.3 { sawBelow = true }
            }
        }
        XCTAssertTrue(sawAbove && sawBelow, "The teeth sway to both sides of the axis")
    }

    func testAStubShorterThanOneToothGetsNothing() {
        XCTAssertTrue(builder.buildPolygons(points: [SIMD2<Float>(100, 500), SIMD2<Float>(102, 500)],
                                            unitsPerMetre: 1).isEmpty)
    }
}
