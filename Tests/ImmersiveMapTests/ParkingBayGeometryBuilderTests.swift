// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The parking-bay comb is laid out the way real lots are painted: stripes
/// across the long axis of the polygon's minimum rectangle, one row deep on a
/// narrow strip, alternating bay row and driving aisle on a deep lot, spread
/// to car-length spacing where the tiles say the parking is parallel, and
/// never a single stroke outside the polygon.
final class ParkingBayGeometryBuilderTests: XCTestCase {
    private let builder = ParkingBayGeometryBuilder()

    /// Tests run with one unit = one metre, so the layout constants read
    /// directly.
    private let metre: Float = 1.0

    private func rectangle(width: Float, depth: Float,
                           rotatedBy angle: Float = 0,
                           at origin: SIMD2<Float> = SIMD2<Float>(500, 500)) -> [SIMD2<Float>] {
        let u = SIMD2<Float>(cos(angle), sin(angle))
        let n = SIMD2<Float>(-sin(angle), cos(angle))
        return [origin,
                origin + u * width,
                origin + u * width + n * depth,
                origin + n * depth]
    }

    func testANarrowStripGetsOneRowOfPerpendicularStripes() {
        let angle: Float = 0.4
        let ring = rectangle(width: 60, depth: 5, rotatedBy: angle)
        let stripes = builder.buildStripes(exterior: ring, unitsPerMetre: metre, orientation: nil)
        // One bay every 2.6 m along 60 m.
        XCTAssertEqual(stripes.count, 23, "A 60 m strip holds a bay every 2.6 metres")
        let axis = SIMD2<Float>(cos(angle), sin(angle))
        for stripe in stripes {
            let direction = simd_normalize(stripe[1] - stripe[0])
            XCTAssertEqual(abs(simd_dot(direction, axis)), 0, accuracy: 1e-3,
                           "Every stripe runs across the long axis")
            XCTAssertEqual(simd_distance(stripe[0], stripe[1]), 5, accuracy: 0.1,
                           "and spans the whole depth of the strip")
        }
    }

    func testADeepLotAlternatesBayRowsAndAisles() {
        let ring = rectangle(width: 60, depth: 30)
        let stripes = builder.buildStripes(exterior: ring, unitsPerMetre: metre, orientation: nil)
        XCTAssertFalse(stripes.isEmpty)
        // Rows at depth 0-5, 11-16 and 22-27: three bands of 5 m stripes
        // separated by 6 m aisles of bare asphalt.
        var bands = Set<Int>()
        for stripe in stripes {
            XCTAssertEqual(simd_distance(stripe[0], stripe[1]), 5, accuracy: 0.1,
                           "A stripe spans one bay row, never the aisle")
            let depth = min(stripe[0].y, stripe[1].y) - 500
            switch depth {
            case -0.1...0.1: bands.insert(0)
            case 10.9...11.1: bands.insert(1)
            case 21.9...22.1: bands.insert(2)
            default: XCTFail("A stripe begins inside an aisle at depth \(depth)")
            }
        }
        XCTAssertEqual(bands, [0, 1, 2], "Three rows fit a 30 m lot")
    }

    func testStripesNeverLeaveAnLShapedPolygon() {
        // An L: a 60x20 body with a 30x20 notch cut from its top-right.
        let ring: [SIMD2<Float>] = [
            SIMD2<Float>(500, 500), SIMD2<Float>(560, 500),
            SIMD2<Float>(560, 510), SIMD2<Float>(530, 510),
            SIMD2<Float>(530, 520), SIMD2<Float>(500, 520)
        ]
        let stripes = builder.buildStripes(exterior: ring, unitsPerMetre: metre, orientation: nil)
        XCTAssertFalse(stripes.isEmpty)
        func inside(_ p: SIMD2<Float>) -> Bool {
            // Inside the L with a small tolerance toward the boundary.
            let e: Float = 0.01
            let body = p.x >= 500 - e && p.x <= 560 + e && p.y >= 500 - e && p.y <= 510 + e
            let foot = p.x >= 500 - e && p.x <= 530 + e && p.y >= 500 - e && p.y <= 520 + e
            return body || foot
        }
        for stripe in stripes {
            XCTAssertTrue(inside(stripe[0]) && inside(stripe[1]),
                          "A stripe stays on the parking asphalt: \(stripe)")
        }
    }

    func testParallelParkingSpreadsTheStripesToCarLength() {
        let ring = rectangle(width: 60, depth: 3)
        let bays = builder.buildStripes(exterior: ring, unitsPerMetre: metre, orientation: nil)
        let parallel = builder.buildStripes(exterior: ring, unitsPerMetre: metre, orientation: "parallel")
        XCTAssertGreaterThan(bays.count, parallel.count * 2,
                             "Parallel spaces are a car length apart, not a bay width")
        XCTAssertGreaterThan(parallel.count, 5, "but the dividers are still there")
    }
}
