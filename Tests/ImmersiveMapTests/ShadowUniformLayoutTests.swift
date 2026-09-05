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
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.uvMinimum), 80)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.uvMaximum), 88)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.normalOffsetWorld), 96)
        XCTAssertEqual(MemoryLayout<ShadowCascadeUniform>.offset(of: \.texelSizeUV), 104)
    }

    func testShadowUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShadowUniform>.stride, 176)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.cascade), 0)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.eye), 112)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.strength), 128)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.fadeStartDistance), 132)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.fadeEndDistance), 136)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.lightDirection), 144)
        XCTAssertEqual(MemoryLayout<ShadowUniform>.offset(of: \.tint), 160)
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

    func testGroundShadowMaskSizeCoversTheDrawable() {
        XCTAssertEqual(GroundShadowMaskPipeline.maskSize(for: CGSize(width: 1290, height: 2796)),
                       CGSize(width: 516, height: 1119))
        XCTAssertEqual(GroundShadowMaskPipeline.maskSize(for: CGSize(width: 1291, height: 2797)),
                       CGSize(width: 517, height: 1119),
                       "A fractional product rounds the mask up so no drawable pixel maps past its edge")
    }

    func testCasterUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<ShadowCasterUniform>.stride, 64)
        XCTAssertEqual(MemoryLayout<ShadowCasterUniform>.offset(of: \.lightProjectionView), 0)
    }

    func testDisabledUniformHasZeroStrengthAndEmptyRects() {
        XCTAssertEqual(ShadowUniform.disabled.strength, 0)
        // Empty rectangle: minimum > maximum, so containment always fails.
        XCTAssertGreaterThan(ShadowUniform.disabled.cascade.uvMinimum.x,
                             ShadowUniform.disabled.cascade.uvMaximum.x)
    }
}
