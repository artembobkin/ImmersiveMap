// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Дымка у горизонта: сила равна фазе перехода (на чистом глобусе тумана нет,
/// на плоскости - полный), цвет берётся из фона карты.
final class HorizonFogUniformTests: XCTestCase {
    func testStrengthEqualsClampedTransition() {
        XCTAssertEqual(makeFog(transition: -0.5).strength, 0)
        XCTAssertEqual(makeFog(transition: 0).strength, 0)
        XCTAssertEqual(makeFog(transition: 0.4).strength, 0.4, accuracy: 1e-6)
        XCTAssertEqual(makeFog(transition: 1).strength, 1)
        XCTAssertEqual(makeFog(transition: 1.5).strength, 1)
    }

    func testColorAndEyeAreCarriedThrough() {
        let fog = HorizonFogUniform.make(transition: 1,
                                         cameraEye: SIMD3<Float>(0.1, -0.4, 0.25),
                                         mapClearColor: SIMD4<Double>(0.9, 0.8, 0.7, 1.0))

        XCTAssertEqual(fog.color.x, 0.9, accuracy: 1e-6)
        XCTAssertEqual(fog.color.y, 0.8, accuracy: 1e-6)
        XCTAssertEqual(fog.color.z, 0.7, accuracy: 1e-6)
        XCTAssertEqual(fog.eye, SIMD3<Float>(0.1, -0.4, 0.25))
        XCTAssertLessThan(fog.startEyeHeights, fog.endEyeHeights)
    }

    func testDisabledFogHasZeroStrength() {
        XCTAssertEqual(HorizonFogUniform.disabled.strength, 0)
    }

    private func makeFog(transition: Float) -> HorizonFogUniform {
        HorizonFogUniform.make(transition: transition,
                               cameraEye: SIMD3<Float>(0, 0, 0.25),
                               mapClearColor: SIMD4<Double>(1, 1, 1, 1))
    }
}
