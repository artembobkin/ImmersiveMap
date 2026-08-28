// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Pins the byte layout of the Swift mirrors of `ShadowCascade`/`Shadow` in
/// RenderUniforms.h: a drifted stride or offset would silently corrupt every
/// shadow lookup.
final class ShadowUniformLayoutTests: XCTestCase {
    func testCascadeUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.stride, 112)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.worldToShadowTexture), 0)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.kernelRadiusUV), 64)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.depthBias), 72)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.gradientClamp), 76)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.uvMinimum), 80)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.uvMaximum), 88)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.normalOffsetWorld), 96)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.texelSizeUV), 104)
    }

    func testShadowUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShadowUniform>.stride, 400)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.cascadeNear), 0)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.cascadeMiddle), 112)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.cascadeFar), 224)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.eye), 336)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.strength), 352)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.fadeStartDistance), 356)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.fadeEndDistance), 360)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.lightDirection), 368)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.tint), 384)
    }

    func testGroundShadowMaskUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<GroundShadowMaskUniform>.stride, 80)
        XCTAssertEqual(MemoryLayout<GroundShadowMaskUniform>.offset(of: \.inverseProjectionView), 0)
        XCTAssertEqual(MemoryLayout<GroundShadowMaskUniform>.offset(of: \.viewportSize), 64)
    }

    func testGroundShadowMaskUniformInvertsTheProjectionView() {
        let projectionView = Matrix.perspectiveMatrix(fovRadians: 1.0, aspect: 1.5, near: 0.1, far: 100)
            * Matrix.translationMatrix(x: 3, y: -2, z: -10)
        let uniform = GroundShadowMaskUniform(projectionView: projectionView,
                                              viewportSize: SIMD2<Float>(1290, 2796))
        let roundTrip = uniform.inverseProjectionView * projectionView
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(roundTrip[column][row], column == row ? 1 : 0, accuracy: 1e-4)
            }
        }
        XCTAssertEqual(uniform.viewportSize, SIMD2<Float>(1290, 2796))
    }

    func testCasterUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShadowCasterUniform>.stride, 192)
        XCTAssertEqual(MemoryLayout<ShadowCasterUniform>.offset(of: \.near), 0)
        XCTAssertEqual(MemoryLayout<ShadowCasterUniform>.offset(of: \.middle), 64)
        XCTAssertEqual(MemoryLayout<ShadowCasterUniform>.offset(of: \.far), 128)
    }

    func testDisabledUniformHasZeroStrengthAndEmptyRects() {
        XCTAssertEqual(ShadowUniform.disabled.strength, 0)
        // Empty rectangle: minimum > maximum, so containment always fails.
        XCTAssertGreaterThan(ShadowUniform.disabled.cascadeNear.uvMinimum.x,
                             ShadowUniform.disabled.cascadeNear.uvMaximum.x)
    }
}
