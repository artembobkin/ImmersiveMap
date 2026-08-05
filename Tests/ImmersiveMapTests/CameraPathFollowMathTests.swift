// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import QuartzCore
import simd
import XCTest

/// The chase math behind a camera following a path: a frame-rate independent
/// catch-up, and a world-X step that crosses the antimeridian the short way.
final class CameraPathFollowMathTests: XCTestCase {

    // MARK: - Catch-up

    func testZeroHalfLifePinsTheCameraOnTheTarget() {
        XCTAssertEqual(CameraPathFollowMath.catchUpFraction(deltaTime: 1.0 / 60.0, halfLife: 0), 1)
        XCTAssertEqual(CameraPathFollowMath.catchUpFraction(deltaTime: 1.0 / 60.0, halfLife: -1), 1)
    }

    func testOneHalfLifeClosesHalfTheGap() {
        // The delta time cap is what makes this reachable in one step.
        let halfLife = CameraPathFollowMath.maximumDeltaTime
        let fraction = CameraPathFollowMath.catchUpFraction(deltaTime: halfLife, halfLife: halfLife)
        XCTAssertEqual(fraction, 0.5, accuracy: 1e-9)
    }

    /// Two half-steps must close the same share of the gap as one full step,
    /// otherwise the chase would depend on the frame rate.
    func testCatchUpIsFrameRateIndependent() {
        let halfLife = 0.4
        let step = 0.02
        let single = CameraPathFollowMath.catchUpFraction(deltaTime: step * 2, halfLife: halfLife)

        var remaining = 1.0
        for _ in 0..<2 {
            remaining *= 1 - CameraPathFollowMath.catchUpFraction(deltaTime: step, halfLife: halfLife)
        }
        XCTAssertEqual(1 - remaining, single, accuracy: 1e-9)
    }

    /// A long stall (a parked view resuming) must not teleport the camera.
    func testLongFrameIsCappedInsteadOfTeleporting() {
        let capped = CameraPathFollowMath.catchUpFraction(deltaTime: 5, halfLife: 0.35)
        let atCap = CameraPathFollowMath.catchUpFraction(deltaTime: CameraPathFollowMath.maximumDeltaTime,
                                                         halfLife: 0.35)
        XCTAssertEqual(capped, atCap, accuracy: 1e-12)
        XCTAssertLessThan(capped, 1)
    }

    /// Same convention as the pitch and bearing followers: a non-finite delta
    /// time yields no step at all rather than a capped one.
    func testNonFiniteDeltaTimeIsIgnored() {
        XCTAssertEqual(CameraPathFollowMath.clampedDeltaTime(.nan), 0)
        XCTAssertEqual(CameraPathFollowMath.clampedDeltaTime(.infinity), 0)
        XCTAssertEqual(CameraPathFollowMath.clampedDeltaTime(-1), 0)
        XCTAssertEqual(CameraBearingFollowMath.clampedDeltaTime(.infinity), 0)
    }

    // MARK: - Center step

    func testShortestWorldXDeltaCrossesTheSeam() {
        // 0.99 -> 0.01 is 0.02 east across the antimeridian, not 0.98 west.
        XCTAssertEqual(CameraPathFollowMath.shortestNormalizedWorldXDelta(current: 0.99, target: 0.01),
                       0.02, accuracy: 1e-12)
        XCTAssertEqual(CameraPathFollowMath.shortestNormalizedWorldXDelta(current: 0.01, target: 0.99),
                       -0.02, accuracy: 1e-12)
        XCTAssertEqual(CameraPathFollowMath.shortestNormalizedWorldXDelta(current: 0.2, target: 0.3),
                       0.1, accuracy: 1e-12)
    }

    func testSteppedCenterCrossesTheSeamAndStaysWrapped() {
        let stepped = CameraPathFollowMath.steppedCenter(current: SIMD2<Double>(0.99, 0.5),
                                                         target: SIMD2<Double>(0.01, 0.5),
                                                         catchUpFraction: 0.5)
        XCTAssertEqual(stepped.x, 0.0, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(stepped.x, 0)
        XCTAssertLessThan(stepped.x, 1)
    }

    func testFullCatchUpLandsExactlyOnTheTarget() {
        let target = SIMD2<Double>(0.25, 0.4)
        let stepped = CameraPathFollowMath.steppedCenter(current: SIMD2<Double>(0.8, 0.9),
                                                         target: target,
                                                         catchUpFraction: 1)
        XCTAssertEqual(stepped.x, target.x, accuracy: 1e-12)
        XCTAssertEqual(stepped.y, target.y, accuracy: 1e-12)
    }

    func testRepeatedStepsConvergeOnAStaticTarget() {
        var center = SIMD2<Double>(0.1, 0.1)
        let target = SIMD2<Double>(0.6, 0.7)
        for _ in 0..<600 {
            center = CameraPathFollowMath.steppedCenter(current: center,
                                                        target: target,
                                                        catchUpFraction: CameraPathFollowMath.catchUpFraction(
                                                            deltaTime: 1.0 / 60.0,
                                                            halfLife: 0.35))
        }
        XCTAssertEqual(center.x, target.x, accuracy: 1e-6)
        XCTAssertEqual(center.y, target.y, accuracy: 1e-6)
    }

    // MARK: - Coordinate conversion

    func testCenterWorldMercatorRoundTrips() {
        let coordinate = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
        let center = CameraPathFollowMath.centerWorldMercator(of: coordinate)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: center.y) * 180.0 / .pi
        let longitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: center.x) * 180.0 / .pi
        XCTAssertEqual(latitude, coordinate.latitude, accuracy: 1e-9)
        XCTAssertEqual(longitude, coordinate.longitude, accuracy: 1e-9)
    }
}

/// The curve is the contract that keeps a followed camera and an animated model
/// on the same point of the path, so it is pinned on its own.
final class ImmersiveMapPathAnimationCurveTests: XCTestCase {
    func testLinearCurveIsProportionalToElapsed() {
        XCTAssertEqual(ImmersiveMapPathAnimationCurve.linear.fraction(elapsed: 0, duration: 10), 0)
        XCTAssertEqual(ImmersiveMapPathAnimationCurve.linear.fraction(elapsed: 5, duration: 10), 0.5)
        XCTAssertEqual(ImmersiveMapPathAnimationCurve.linear.fraction(elapsed: 10, duration: 10), 1)
    }

    func testEaseOutIsCubic() {
        // 1 - (1 - 0.5)^3 = 0.875
        XCTAssertEqual(ImmersiveMapPathAnimationCurve.easeOut.fraction(elapsed: 5, duration: 10),
                       0.875, accuracy: 1e-12)
    }

    func testFractionIsClampedAndDegenerateDurationsFinishImmediately() {
        XCTAssertEqual(ImmersiveMapPathAnimationCurve.linear.fraction(elapsed: -5, duration: 10), 0)
        XCTAssertEqual(ImmersiveMapPathAnimationCurve.linear.fraction(elapsed: 50, duration: 10), 1)
        XCTAssertEqual(ImmersiveMapPathAnimationCurve.easeOut.fraction(elapsed: 1, duration: 0), 1)
    }
}
