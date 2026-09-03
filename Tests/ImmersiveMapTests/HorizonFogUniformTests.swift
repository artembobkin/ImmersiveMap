// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Horizon haze: strength equals the transition phase (no fog on a pure globe,
/// full fog on the plane); the color comes from the map background.
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
        XCTAssertEqual(HorizonFogUniform.disabled.hazeStrength, 0)
    }

    /// The layout is a binding contract with `HorizonFog` in
    /// RenderUniforms.h and `FlatSky` in Atmosphere.metal: two float3
    /// (16-byte aligned), five floats, a float3, four floats.
    func testLayoutMatchesTheShaderStructs() {
        XCTAssertEqual(MemoryLayout<HorizonFogUniform>.stride, 80)
        XCTAssertEqual(MemoryLayout<HorizonFogUniform>.offset(of: \.hazeColor), 48)
        XCTAssertEqual(MemoryLayout<HorizonFogUniform>.offset(of: \.skyBandRadians), 76)
        XCTAssertEqual(MemoryLayout<FlatSkyUniform>.stride, 64 + 80)
        XCTAssertEqual(MemoryLayout<FlatSkyUniform>.offset(of: \.fog), 64)
    }

    /// The haze: the halo's tint, on unless space is transparent (no sky is
    /// painted there, so the ground must still meet the clear colour).
    func testHazeFollowsTheAtmosphereAndTransparentSpaceTurnsItOff() {
        let fog = makeFog(transition: 1)
        XCTAssertEqual(fog.hazeStrength, 1)
        XCTAssertEqual(fog.hazeColor, AtmosphereUniform.haloColor)
        XCTAssertGreaterThan(fog.glowRadians, fog.bandRadians)
        XCTAssertGreaterThan(fog.bandRadians, fog.whitenRadians)
        let bare = HorizonFogUniform.make(transition: 1,
                                          cameraEye: SIMD3<Float>(0, 0, 0.25),
                                          mapClearColor: SIMD4<Double>(1, 1, 1, 1),
                                          hazeEnabled: false)
        XCTAssertEqual(bare.hazeStrength, 0)
    }

    /// The haze profile: saturated at the line, a faint glow far below it,
    /// nothing under the camera.
    func testHazeAmountSaturatesAtTheHorizonAndThinsDownward() {
        XCTAssertEqual(HorizonFogUniform.hazeAmount(belowRadians: 0), 1)
        let tenDegrees = HorizonFogUniform.hazeAmount(belowRadians: 10 * .pi / 180)
        let thirtyDegrees = HorizonFogUniform.hazeAmount(belowRadians: 30 * .pi / 180)
        XCTAssertGreaterThan(tenDegrees, thirtyDegrees)
        XCTAssertLessThan(tenDegrees, 0.5, "Ten degrees under the horizon is thin haze, not fog")
        XCTAssertLessThan(thirtyDegrees, 0.03, "Thirty degrees under the line is a faint tint of air")
        XCTAssertEqual(HorizonFogUniform.hazeAmount(belowRadians: HorizonFogUniform.hazeCutoffEndRadians), 0,
                       "Past the cutoff the haze is exactly zero")
        XCTAssertEqual(HorizonFogUniform.hazeAmount(belowRadians: .pi / 2), 0,
                       "Straight down the map stays byte-clean")
        XCTAssertGreaterThan(HorizonFogUniform.hazeAmount(belowRadians: 0.5 * .pi / 180), 0.95,
                             "Half a degree under the line the haze is already the sky")
    }

    private func makeFog(transition: Float) -> HorizonFogUniform {
        HorizonFogUniform.make(transition: transition,
                               cameraEye: SIMD3<Float>(0, 0, 0.25),
                               mapClearColor: SIMD4<Double>(1, 1, 1, 1))
    }
}
