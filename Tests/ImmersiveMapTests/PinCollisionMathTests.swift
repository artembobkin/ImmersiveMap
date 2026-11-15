// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class PinCollisionMathTests: XCTestCase {
    func testSmoothingFactorIsZeroWithoutElapsedTime() {
        XCTAssertEqual(PinCollisionMath.smoothingFactor(smoothing: 0.5, deltaSeconds: 0), 0.0)
    }

    func testSmoothingFactorIsFrameRateIndependent() {
        // One 1/30 step must cover the same fraction of the path as two 1/60 steps.
        let single = PinCollisionMath.smoothingFactor(smoothing: 0.35, deltaSeconds: 1.0 / 30.0)
        let half = PinCollisionMath.smoothingFactor(smoothing: 0.35, deltaSeconds: 1.0 / 60.0)
        let doubled = 1.0 - (1.0 - half) * (1.0 - half)
        XCTAssertEqual(single, doubled, accuracy: 0.0001)
    }

    func testStableUnitDirectionIsDeterministicUnitVectorAndOrderIndependent() {
        let direction = PinCollisionMath.stableUnitDirection(idA: 7, idB: 42)
        let swapped = PinCollisionMath.stableUnitDirection(idA: 42, idB: 7)
        XCTAssertEqual(simd_length(direction), 1.0, accuracy: 0.0001)
        XCTAssertEqual(direction, swapped)
        XCTAssertEqual(direction, PinCollisionMath.stableUnitDirection(idA: 7, idB: 42))
    }

    func testRequiredScaleIsForcedOnlyByLackOfSpace() {
        // The distance is enough for full bodies: no compression needed.
        XCTAssertEqual(PinCollisionMath.requiredScale(distance: 120,
                                                         bodyRadius: 50,
                                                         otherBodyRadius: 50,
                                                         padding: 8,
                                                         otherIsRigid: false),
                       1.0)
        // No room: the pair splits the shortfall evenly.
        XCTAssertEqual(PinCollisionMath.requiredScale(distance: 66,
                                                         bodyRadius: 50,
                                                         otherBodyRadius: 50,
                                                         padding: 8,
                                                         otherIsRigid: false),
                       0.5,
                       accuracy: 0.0001)
        // The neighbor is incompressible (selected/cluster): the whole shortfall falls on the current one.
        XCTAssertEqual(PinCollisionMath.requiredScale(distance: 91,
                                                         bodyRadius: 50,
                                                         otherBodyRadius: 50,
                                                         padding: 8,
                                                         otherIsRigid: true),
                       0.5,
                       accuracy: 0.0001)
    }

    func testScaleCapKeepsDisplacedCirclesSmallerThanPins() {
        XCTAssertEqual(PinCollisionMath.scaleCap(morph: 0.0), 1.0)
        XCTAssertEqual(PinCollisionMath.scaleCap(morph: 1.0),
                       PinCollisionMath.displacedCircleScale,
                       accuracy: 0.0001)
        let partial = PinCollisionMath.scaleCap(morph: 0.5)
        XCTAssertGreaterThan(partial, PinCollisionMath.displacedCircleScale)
        XCTAssertLessThan(partial, 1.0)
    }

    func testFlowerLayoutPacksTouchingPetalsAroundCenter() {
        // Adjacent petals touch: the center distance equals 2 * body radius.
        let petalRadius: Float = 30.0
        let count = 5
        let ring = PinCollisionMath.flowerRingRadius(petalBodyRadius: petalRadius, petalCount: count)
        for index in 0..<count {
            let current = PinCollisionMath.flowerPetalOffset(index: index, petalCount: count, ringRadius: ring)
            let next = PinCollisionMath.flowerPetalOffset(index: (index + 1) % count,
                                                             petalCount: count,
                                                             ringRadius: ring)
            XCTAssertEqual(simd_length(current), ring, accuracy: 0.001)
            XCTAssertEqual(simd_length(current - next), petalRadius * 2.0, accuracy: 0.01)
        }

        // A pair of petals stands side by side.
        XCTAssertEqual(PinCollisionMath.flowerRingRadius(petalBodyRadius: petalRadius, petalCount: 2),
                       petalRadius,
                       accuracy: 0.001)
        XCTAssertEqual(PinCollisionMath.flowerRingRadius(petalBodyRadius: petalRadius, petalCount: 1), 0.0)
    }

    func testDisplacedMorphTurnsShiftedPinIntoCircle() {
        // Only a pin exactly on its geo point gets the pin shape; any offset means a circle.
        XCTAssertEqual(PinCollisionMath.displacedMorph(offsetLength: 0.0), 0.0)
        XCTAssertEqual(PinCollisionMath.displacedMorph(offsetLength: PinCollisionMath.displacedMorphEndPx),
                       1.0,
                       accuracy: 0.0001)
        XCTAssertEqual(PinCollisionMath.displacedMorph(offsetLength: 100.0), 1.0)
        let partial = PinCollisionMath.displacedMorph(offsetLength: 6.0)
        XCTAssertGreaterThan(partial, 0.0)
        XCTAssertLessThan(partial, 1.0)
    }

    func testBadgeContentAlphaHidesBadgesWhenCompressed() {
        XCTAssertEqual(PinCollisionMath.badgeContentAlpha(displayScale: 1.0), 1.0)
        XCTAssertEqual(PinCollisionMath.badgeContentAlpha(displayScale: 0.55), 0.0)
        let partial = PinCollisionMath.badgeContentAlpha(displayScale: 0.9)
        XCTAssertGreaterThan(partial, 0.0)
        XCTAssertLessThan(partial, 1.0)
    }
}
