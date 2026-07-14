// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class AvatarCollisionMathTests: XCTestCase {
    func testSmoothingFactorIsZeroWithoutElapsedTime() {
        XCTAssertEqual(AvatarCollisionMath.smoothingFactor(smoothing: 0.5, deltaSeconds: 0), 0.0)
    }

    func testSmoothingFactorIsFrameRateIndependent() {
        // Один шаг 1/30 должен съедать ту же долю пути, что два шага 1/60.
        let single = AvatarCollisionMath.smoothingFactor(smoothing: 0.35, deltaSeconds: 1.0 / 30.0)
        let half = AvatarCollisionMath.smoothingFactor(smoothing: 0.35, deltaSeconds: 1.0 / 60.0)
        let doubled = 1.0 - (1.0 - half) * (1.0 - half)
        XCTAssertEqual(single, doubled, accuracy: 0.0001)
    }

    func testStableUnitDirectionIsDeterministicUnitVectorAndOrderIndependent() {
        let direction = AvatarCollisionMath.stableUnitDirection(idA: 7, idB: 42)
        let swapped = AvatarCollisionMath.stableUnitDirection(idA: 42, idB: 7)
        XCTAssertEqual(simd_length(direction), 1.0, accuracy: 0.0001)
        XCTAssertEqual(direction, swapped)
        XCTAssertEqual(direction, AvatarCollisionMath.stableUnitDirection(idA: 7, idB: 42))
    }

    func testRequiredScaleIsForcedOnlyByLackOfSpace() {
        // Дистанции хватает для полных тел: сжатие не требуется.
        XCTAssertEqual(AvatarCollisionMath.requiredScale(distance: 120,
                                                         bodyRadius: 50,
                                                         otherBodyRadius: 50,
                                                         padding: 8,
                                                         otherIsRigid: false),
                       1.0)
        // Места нет: пара делит нехватку поровну.
        XCTAssertEqual(AvatarCollisionMath.requiredScale(distance: 66,
                                                         bodyRadius: 50,
                                                         otherBodyRadius: 50,
                                                         padding: 8,
                                                         otherIsRigid: false),
                       0.5,
                       accuracy: 0.0001)
        // Сосед несжимаемый (выбранный/кластер): вся нехватка на текущем.
        XCTAssertEqual(AvatarCollisionMath.requiredScale(distance: 91,
                                                         bodyRadius: 50,
                                                         otherBodyRadius: 50,
                                                         padding: 8,
                                                         otherIsRigid: true),
                       0.5,
                       accuracy: 0.0001)
    }

    func testScaleCapKeepsDisplacedCirclesSmallerThanPins() {
        XCTAssertEqual(AvatarCollisionMath.scaleCap(morph: 0.0), 1.0)
        XCTAssertEqual(AvatarCollisionMath.scaleCap(morph: 1.0),
                       AvatarCollisionMath.displacedCircleScale,
                       accuracy: 0.0001)
        let partial = AvatarCollisionMath.scaleCap(morph: 0.5)
        XCTAssertGreaterThan(partial, AvatarCollisionMath.displacedCircleScale)
        XCTAssertLessThan(partial, 1.0)
    }

    func testFlowerLayoutPacksTouchingPetalsAroundCenter() {
        // Соседние лепестки касаются: дистанция центров равна 2 * радиус тела.
        let petalRadius: Float = 30.0
        let count = 5
        let ring = AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalRadius, petalCount: count)
        for index in 0..<count {
            let current = AvatarCollisionMath.flowerPetalOffset(index: index, petalCount: count, ringRadius: ring)
            let next = AvatarCollisionMath.flowerPetalOffset(index: (index + 1) % count,
                                                             petalCount: count,
                                                             ringRadius: ring)
            XCTAssertEqual(simd_length(current), ring, accuracy: 0.001)
            XCTAssertEqual(simd_length(current - next), petalRadius * 2.0, accuracy: 0.01)
        }

        // Пара лепестков стоит бок о бок.
        XCTAssertEqual(AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalRadius, petalCount: 2),
                       petalRadius,
                       accuracy: 0.001)
        XCTAssertEqual(AvatarCollisionMath.flowerRingRadius(petalBodyRadius: petalRadius, petalCount: 1), 0.0)
    }

    func testDisplacedMorphTurnsShiftedMarkerIntoCircle() {
        // Форма пина только у маркера ровно на геоточке; любой сдвиг - кружок.
        XCTAssertEqual(AvatarCollisionMath.displacedMorph(offsetLength: 0.0), 0.0)
        XCTAssertEqual(AvatarCollisionMath.displacedMorph(offsetLength: AvatarCollisionMath.displacedMorphEndPx),
                       1.0,
                       accuracy: 0.0001)
        XCTAssertEqual(AvatarCollisionMath.displacedMorph(offsetLength: 100.0), 1.0)
        let partial = AvatarCollisionMath.displacedMorph(offsetLength: 6.0)
        XCTAssertGreaterThan(partial, 0.0)
        XCTAssertLessThan(partial, 1.0)
    }

    func testBadgeContentAlphaHidesBadgesWhenCompressed() {
        XCTAssertEqual(AvatarCollisionMath.badgeContentAlpha(displayScale: 1.0), 1.0)
        XCTAssertEqual(AvatarCollisionMath.badgeContentAlpha(displayScale: 0.55), 0.0)
        let partial = AvatarCollisionMath.badgeContentAlpha(displayScale: 0.9)
        XCTAssertGreaterThan(partial, 0.0)
        XCTAssertLessThan(partial, 1.0)
    }
}
