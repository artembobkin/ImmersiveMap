// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The sphere as an occluder, stated on the CPU mirror of
/// `globeOcclusionClearance`: what the planet hides from the eye is negative,
/// what the eye sees is positive, and the branches meet without a step.
final class GlobeOcclusionMathTests: XCTestCase {
    private let radius: Float = 1.0

    /// A point of the sphere at angular distance `theta` from the tangent
    /// point, in the x-z plane; the globe's centre is at (0, 0, -radius).
    private func spherePoint(theta: Float) -> SIMD3<Float> {
        SIMD3<Float>(radius * sin(theta), 0, radius * (cos(theta) - 1))
    }

    func testTheEyeStraightAboveSeesTheNearCapAndNotBeyondTheHorizon() {
        let eye = SIMD3<Float>(0, 0, 1)   // two radii from the centre: the horizon is at 60 degrees
        XCTAssertGreaterThan(GlobeOcclusionMath.clearance(position: .zero, eye: eye, radius: radius), 0,
                             "The tangent point sits on the sphere and is seen: the margin keeps it positive")
        XCTAssertGreaterThan(GlobeOcclusionMath.clearance(position: spherePoint(theta: 0.5), eye: eye, radius: radius), 0)
        XCTAssertLessThan(GlobeOcclusionMath.clearance(position: spherePoint(theta: 2.0), eye: eye, radius: radius), 0,
                          "Beyond the horizon the segment from the eye enters the planet first")
        XCTAssertLessThan(GlobeOcclusionMath.clearance(position: SIMD3<Float>(0, 0, -radius), eye: eye, radius: radius), 0,
                          "The centre of the planet is inside it")
        let limb = GlobeOcclusionMath.clearance(position: spherePoint(theta: .pi / 3), eye: eye, radius: radius)
        XCTAssertEqual(limb, 0, accuracy: 1e-3, "On the limb the segment grazes the sphere")
    }

    func testThePlaneAheadOfATiltedCameraIsClear() {
        // Pitch 75 degrees, 0.7 from the tangent point: the flat map far ahead
        // lies above the rays that graze the planet.
        let eye = SIMD3<Float>(0, -0.7 * sin(1.309), 0.7 * cos(1.309))
        XCTAssertGreaterThan(GlobeOcclusionMath.clearance(position: SIMD3<Float>(0, 5, 0), eye: eye, radius: radius), 0)
        XCTAssertGreaterThan(GlobeOcclusionMath.clearance(position: SIMD3<Float>(3, 20, 0), eye: eye, radius: radius), 0)
        XCTAssertLessThan(GlobeOcclusionMath.clearance(position: SIMD3<Float>(0, 5, -1.5), eye: eye, radius: radius), 0,
                          "A point far ahead but deep below the plane is behind the planet")
    }

    func testTheBranchesMeetWithoutAStep() {
        let eye = SIMD3<Float>(0, 0, 1)
        // The closest approach lands on the point itself when the point is the
        // centre: the branch for a point before the closest approach and the
        // branch for a segment passing it agree there.
        let before = GlobeOcclusionMath.clearance(position: SIMD3<Float>(0, 0, 1 - 1.999), eye: eye, radius: radius)
        let after = GlobeOcclusionMath.clearance(position: SIMD3<Float>(0, 0, 1 - 2.001), eye: eye, radius: radius)
        XCTAssertEqual(before, after, accuracy: 1e-2)
        // The closest approach lands on the eye when the point is next to it.
        let behindTheEye = GlobeOcclusionMath.clearance(position: eye + SIMD3<Float>(0, 0, 1e-3), eye: eye, radius: radius)
        let inFrontOfTheEye = GlobeOcclusionMath.clearance(position: eye - SIMD3<Float>(0, 0, 1e-3), eye: eye, radius: radius)
        XCTAssertEqual(behindTheEye, inFrontOfTheEye, accuracy: 1e-2)
        XCTAssertGreaterThan(behindTheEye, 0, "The planet is behind the camera, which is always outside it")
    }

    func testTheMarginMatchesTheShader() {
        XCTAssertEqual(GlobeOcclusionMath.radiusMargin, 1.0e-4)
    }
}
