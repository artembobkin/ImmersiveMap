// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The mask pass replaces the screen-space derivative gradient with an
/// analytic per-cascade constant: dz/d(u,v) of the ground plane under the
/// cascade's affine projection. The CPU solve must agree with numeric
/// differentiation of the very matrix the shader projects with; otherwise
/// the receiver-plane bias would mispredict and the ground would stripe.
final class GroundPlaneGradientTests: XCTestCase {
    func testAnalyticGradientMatchesNumericDifferentiation() throws {
        let state = try XCTUnwrap(ShadowFrameStateResolver.resolve(
            renderSurfaceMode: .flat,
            cameraEye: SIMD3<Float>(0.2, -0.35, 0.7),
            centerWorldMercator: SIMD2<Double>(0.5, 0.5),
            flatRenderPan: SIMD2<Double>(0.312, -0.144),
            renderMapSize: 2.0 * Double.pi * 0.14 * pow(2.0, 16),
            scene: ImmersiveMapSettings.default.scene))

        for cascade in state.shadowUniform.cascades {
            let analytic = GroundShadowMaskUniform.groundPlaneGradient(cascade: cascade)

            // Numeric: move on the plane along world X and Y, read how the
            // projected (u, v, z) responds, and solve the same 2x2 system.
            let m = cascade.worldToShadowTexture
            func project(_ x: Float, _ y: Float) -> SIMD3<Float> {
                let p = m * SIMD4<Float>(x, y, 0, 1)
                return SIMD3<Float>(p.x, p.y, p.z) / p.w
            }
            let origin = project(0, 0)
            let step: Float = 0.25
            let dx = (project(step, 0) - origin) / step
            let dy = (project(0, step) - origin) / step
            let det = dx.x * dy.y - dy.x * dx.y
            XCTAssertGreaterThan(abs(det), 1e-12)
            let dzdu = (dy.y * dx.z - dx.y * dy.z) / det
            let dzdv = (dx.x * dy.z - dy.x * dx.z) / det

            // The default sun is well inside the clamp, so the analytic value
            // must be the raw solve, not the clamped rim.
            XCTAssertEqual(analytic.x, dzdu, accuracy: max(1e-5, abs(dzdu) * 1e-3))
            XCTAssertEqual(analytic.y, dzdv, accuracy: max(1e-5, abs(dzdv) * 1e-3))
        }
    }

    func testDegenerateProjectionYieldsZeroGradient() {
        XCTAssertEqual(GroundShadowMaskUniform.groundPlaneGradient(cascade: .disabled), .zero)
    }
}
