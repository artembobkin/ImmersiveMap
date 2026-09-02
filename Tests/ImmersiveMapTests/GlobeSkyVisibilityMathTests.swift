// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The frame-level sky test that gates the space décor: four corner rays
/// against the sphere, sky visible iff any corner misses it. The camera
/// here is a plain perspective looking down the -z axis at a sphere whose
/// top touches the origin, the way the globe is placed.
final class GlobeSkyVisibilityMathTests: XCTestCase {
    private func projectionView(eyeZ: Float) -> matrix_float4x4 {
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4,
                                                  aspect: 1,
                                                  near: 0.01,
                                                  far: 200)
        var view = matrix_identity_float4x4
        view.columns.3 = SIMD4<Float>(0, 0, -eyeZ, 1)
        return projection * view
    }

    /// Far above a small planet, the corners look past it into space.
    func testFarCameraSeesSky() {
        let radius: Float = 0.14
        XCTAssertTrue(GlobeSkyVisibilityMath.isSkyVisible(
            inverseProjectionView: simd_inverse(projectionView(eyeZ: 1.0)),
            eye: SIMD3<Float>(0, 0, 1.0),
            radius: radius))
    }

    /// Close over a large planet, every corner ray ends on the surface: the
    /// whole frame is ground and the décor is skipped.
    func testCloseCameraOverALargePlanetSeesNoSky() {
        let radius: Float = 9.0
        XCTAssertFalse(GlobeSkyVisibilityMath.isSkyVisible(
            inverseProjectionView: simd_inverse(projectionView(eyeZ: 0.6)),
            eye: SIMD3<Float>(0, 0, 0.6),
            radius: radius))
    }

    /// The gate must fail open: a planet fully behind the eye is all sky.
    func testPlanetBehindTheEyeIsSky() {
        let radius: Float = 0.5
        var view = matrix_identity_float4x4
        // Looking along -z from far in front while the sphere (top at the
        // origin, centre at -radius) sits behind the near plane is still a
        // hit; place the eye below the sphere looking away instead.
        view = matrix_identity_float4x4
        view.columns.3 = SIMD4<Float>(0, 0, 5, 1)
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4, aspect: 1, near: 0.01, far: 200)
        // Eye at z = -5 (beyond the sphere), looking further along -z: the
        // sphere is behind.
        let pv = projection * view
        XCTAssertTrue(GlobeSkyVisibilityMath.isSkyVisible(
            inverseProjectionView: simd_inverse(pv),
            eye: SIMD3<Float>(0, 0, -5),
            radius: radius))
    }
}
