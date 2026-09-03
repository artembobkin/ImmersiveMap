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
    /// RenderUniforms.h: two float3 (16-byte aligned), four floats, a
    /// float3, four floats.
    func testLayoutMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<HorizonFogUniform>.stride, 80)
        XCTAssertEqual(MemoryLayout<HorizonFogUniform>.offset(of: \.hazeColor), 48)
        XCTAssertEqual(MemoryLayout<HorizonFogUniform>.offset(of: \.limbRadius), 76)
    }

    /// The haze: the halo's tint, ramping in over the first tenth of the
    /// morph, off under transparent space (no sky is painted there, so the
    /// ground must still meet the clear colour).
    func testHazeFollowsTheAtmosphereAndTransparentSpaceTurnsItOff() {
        XCTAssertEqual(makeFog(transition: 0).hazeStrength, 0)
        XCTAssertEqual(makeFog(transition: 0.05).hazeStrength, 0.5, accuracy: 1e-6)
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

    /// The edge the haze is measured from: the sphere the surface lives on
    /// through the unroll (radius R / (1 - t), GlobeUnroll.h), the plane at
    /// the end; the widths morph from the resting halo's to the plane's.
    func testEdgeSphereAndWidthsFollowTheUnroll() {
        let eye = SIMD3<Float>(0, -0.5, 1.5)
        XCTAssertEqual(HorizonFogUniform.limbRadius(geometryTransition: 0, globeRadius: 2), 2)
        XCTAssertEqual(HorizonFogUniform.limbRadius(geometryTransition: 0.5, globeRadius: 2), 4)
        XCTAssertEqual(HorizonFogUniform.limbRadius(geometryTransition: 1, globeRadius: 2), 0, "The plane has no sphere")
        let resting = HorizonFogUniform.hazeWidths(transition: 0, cameraEye: eye, globeRadius: 1)
        let plane = HorizonFogUniform.hazeWidths(transition: 1, cameraEye: eye, globeRadius: 1)
        // At the resting sphere the widths are the halo's radii over the
        // distance to the limb: eye at distance sqrt(0.25 + 6.25) = 2.55
        // from the centre, limb at sqrt(6.5 - 1) = 2.345.
        XCTAssertEqual(resting.band, 0.075 / 2.345, accuracy: 1e-3)
        XCTAssertEqual(plane.band, HorizonFogUniform.planeBandRadians, accuracy: 1e-6)
        XCTAssertEqual(plane.glow, HorizonFogUniform.planeGlowRadians, accuracy: 1e-6)
        let made = HorizonFogUniform.make(transition: 0.5, geometryTransition: 0.5, cameraEye: eye,
                                          mapClearColor: SIMD4<Double>(1, 1, 1, 1), globeRadius: 1)
        XCTAssertEqual(made.limbRadius, 2)
    }

    /// The halo widths the haze starts from are the shader's constants.
    func testHaloWidthsMirrorTheAtmosphereShader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("ImmersiveMap/Render/Shaders/Atmosphere/Atmosphere.metal"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("constant float kAtmosphereBandWidth = 0.075;"))
        XCTAssertTrue(source.contains("constant float kAtmosphereGlowWidth = 0.34;"))
        XCTAssertTrue(source.contains("constant float kAtmosphereWhitenWidth = 0.018;"))
        XCTAssertTrue(source.contains("constant float kAtmosphereHandoverEnd = 0.1;"))
        XCTAssertEqual(HorizonFogUniform.hazeRampEnd, 0.1)
    }

    /// The plane's haze: saturated at the line, thin a glow width under it,
    /// exactly zero under the camera.
    func testPlaneHazeAmountSaturatesAtTheHorizonAndThinsDownward() {
        XCTAssertEqual(HorizonFogUniform.planeHazeAmount(belowRadians: 0), 1)
        let fiveDegrees = HorizonFogUniform.planeHazeAmount(belowRadians: 5 * .pi / 180)
        let fifteenDegrees = HorizonFogUniform.planeHazeAmount(belowRadians: 15 * .pi / 180)
        XCTAssertGreaterThan(fiveDegrees, fifteenDegrees)
        XCTAssertLessThan(fiveDegrees, 0.25, "Five degrees under the line is a thin haze, not fog")
        XCTAssertLessThan(fifteenDegrees, 0.05, "Fifteen degrees under the line the map is nearly clean")
        XCTAssertEqual(HorizonFogUniform.planeHazeAmount(belowRadians: 30 * .pi / 180), 0,
                       "Past the cutoff the haze is exactly zero")
        XCTAssertGreaterThan(HorizonFogUniform.planeHazeAmount(belowRadians: 0.3 * .pi / 180), 0.9,
                             "A third of a degree under the line the haze is already the sky")
    }

    private func makeFog(transition: Float) -> HorizonFogUniform {
        HorizonFogUniform.make(transition: transition,
                               cameraEye: SIMD3<Float>(0, 0, 0.25),
                               mapClearColor: SIMD4<Double>(1, 1, 1, 1))
    }
}
