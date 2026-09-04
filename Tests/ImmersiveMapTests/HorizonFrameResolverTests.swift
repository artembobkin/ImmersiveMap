// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The per-frame schedule of the horizon layer: the atmosphere on the
/// resting globe, the fog band on the plane, and the handover between them
/// through the morph.
final class HorizonFrameResolverTests: XCTestCase {
    private let radius: Float = 0.28

    // MARK: - The resting globe

    func testTheRestingGlobeWearsTheAtmosphere() {
        let haze = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical)
        let atmosphere = ImmersiveMapSettings.default.scene.atmosphere
        XCTAssertTrue(atmosphere.isEnabled, "The atmosphere is on by default, as it shipped")
        XCTAssertEqual(haze.skyStrength, atmosphere.intensity)
        XCTAssertEqual(haze.tint, atmosphere.color)
        XCTAssertEqual(haze.whitenWeight, HorizonFrameResolver.haloWhitenWeight)
        XCTAssertEqual(haze.sunInfluence, atmosphere.sunInfluence, accuracy: 1e-6)
        XCTAssertEqual(haze.groundGain, atmosphere.intensity)
        XCTAssertEqual(haze.featherStrength, HorizonFrameResolver.featherPeakStrength)
        XCTAssertTrue(haze.drawsSky)
        XCTAssertTrue(haze.drawsGround)

        // The shell as a fraction of the planet, seen as angle at the limb.
        let centerDistance = 1 + radius
        let limbDistance = (centerDistance * centerDistance - radius * radius).squareRoot()
        XCTAssertEqual(haze.bandRadians, HorizonFrameResolver.haloBandRadii * radius / limbDistance, accuracy: 1e-5)
        XCTAssertEqual(haze.glowRadians, HorizonFrameResolver.haloGlowRadii * radius / limbDistance, accuracy: 1e-5)
        XCTAssertEqual(haze.groundBandRadians, HorizonFrameResolver.haloRimRadii * radius / limbDistance, accuracy: 1e-5)
        XCTAssertEqual(haze.cutoffStartRadians, haze.groundBandRadians * HorizonFrameResolver.rimCutoffStartWidths, accuracy: 1e-5)
        XCTAssertEqual(haze.cutoffEndRadians, haze.groundBandRadians * HorizonFrameResolver.rimCutoffEndWidths, accuracy: 1e-5)
    }

    func testThicknessStretchesTheHalo() {
        var settings = ImmersiveMapSettings.default
        settings.scene.atmosphere.thickness = 2
        let thick = resolve(settings: settings, transition: 0, geometryTransition: 0, mode: .spherical)
        let designed = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical)
        XCTAssertEqual(thick.bandRadians, designed.bandRadians * 2, accuracy: 1e-5)
        XCTAssertEqual(thick.glowRadians, designed.glowRadians * 2, accuracy: 1e-5)
    }

    /// Off leaves the feather alone: no halo, no rim, no sun, the fog
    /// colour as the feather's tint, and both draws still on (the feather
    /// paints half over space and half over the mesh edge).
    func testTheAtmosphereOffKeepsOnlyTheFeather() {
        let settings = ImmersiveMapSettings.default.atmosphere(isEnabled: false)
        let haze = resolve(settings: settings, transition: 0, geometryTransition: 0, mode: .spherical)
        XCTAssertEqual(haze.skyStrength, 0)
        XCTAssertEqual(haze.groundGain, 0)
        XCTAssertEqual(haze.whitenWeight, 0)
        XCTAssertEqual(haze.sunInfluence, 0)
        XCTAssertEqual(haze.tint, fogColor(settings))
        XCTAssertEqual(haze.featherStrength, HorizonFrameResolver.featherPeakStrength)
        XCTAssertTrue(haze.drawsSky)
        XCTAssertTrue(haze.drawsGround)
    }

    /// The feather is sized in pixels, not in angle.
    func testTheFeatherIsAFixedNumberOfPixels() {
        let small = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical, heightPx: 200)
        let large = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical, heightPx: 2000)
        XCTAssertEqual(small.featherRadians, HorizonFrameResolver.featherPixels * (.pi / 4) / 200, accuracy: 1e-7)
        XCTAssertEqual(large.featherRadians, small.featherRadians / 10, accuracy: 1e-7)
    }

    func testTransparentSpaceSkipsTheSkySide() {
        let haze = resolve(settings: .default.transparentSpace(), transition: 0, geometryTransition: 0, mode: .spherical)
        XCTAssertFalse(haze.drawsSky, "Nothing may be painted around the globe")
        XCTAssertTrue(haze.drawsGround, "The rim and the inner half of the feather stay")
    }

    // MARK: - The plane

    func testThePlaneHasOnlyTheFogBand() {
        let settings = ImmersiveMapSettings.default
        let haze = resolve(settings: settings, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(haze.edge.depression, 0)
        XCTAssertEqual(haze.edge.up, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(haze.skyStrength, 0)
        XCTAssertEqual(haze.featherStrength, 0)
        XCTAssertEqual(haze.whitenWeight, 0)
        XCTAssertEqual(haze.sunInfluence, 0)
        XCTAssertEqual(haze.tint, fogColor(settings))
        XCTAssertEqual(haze.groundGain, HorizonFrameResolver.fogGain, accuracy: 1e-6)
        XCTAssertEqual(haze.groundBandRadians, HorizonFrameResolver.fogBandRadians, accuracy: 1e-6)
        XCTAssertEqual(haze.cutoffStartRadians, HorizonFrameResolver.fogCutoffStartRadians, accuracy: 1e-6)
        XCTAssertEqual(haze.cutoffEndRadians, HorizonFrameResolver.fogCutoffEndRadians, accuracy: 1e-6)
        XCTAssertFalse(haze.drawsSky, "The flat map has no atmosphere: nothing above the horizon is painted")
        XCTAssertTrue(haze.drawsGround, "Pitched almost to the horizon, the band is in the frame")
    }

    /// The fog band does not depend on the atmosphere switch.
    func testTheFogBandIsRequired() {
        let on = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        let off = resolve(settings: .default.atmosphere(isEnabled: false), transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(on, off)
    }

    /// The fog colour is the map's clear colour, so the ground meets the
    /// sky above the line in one colour.
    func testTheFogColourFollowsTheClearColour() {
        var settings = ImmersiveMapSettings.default
        settings.scene.mapClearColor = SIMD4<Double>(0.1, 0.5, 0.9, 1)
        let haze = resolve(settings: settings, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(haze.tint, SIMD3<Float>(0.1, 0.5, 0.9))
    }

    /// Looking down at street pitch, the horizon is far outside the frame
    /// and the layer draws nothing at all.
    func testALowPitchSkipsBothDraws() {
        let haze = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 0.3)
        XCTAssertFalse(haze.drawsSky)
        XCTAssertFalse(haze.drawsGround)
    }

    // MARK: - The morph

    /// Before the handover window nothing changes; through it the halo fades
    /// out and the rim widens into the fog band; at its end the globe path
    /// renders exactly the plane's fog band, so the surface switch happens
    /// between identical frames.
    func testTheMorphHandsTheAtmosphereOverToTheFogBand() {
        let resting = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical)
        let beforeHandover = resolve(settings: .default,
                                     transition: HorizonFrameResolver.handoverStart,
                                     geometryTransition: HorizonFrameResolver.handoverStart / 0.9,
                                     mode: .spherical)
        XCTAssertEqual(beforeHandover.skyStrength, resting.skyStrength)
        XCTAssertEqual(beforeHandover.tint, resting.tint)
        XCTAssertEqual(beforeHandover.featherStrength, resting.featherStrength)

        let midway = resolve(settings: .default, transition: 0.7, geometryTransition: 0.7 / 0.9, mode: .spherical)
        XCTAssertGreaterThan(midway.skyStrength, 0)
        XCTAssertLessThan(midway.skyStrength, resting.skyStrength)
        XCTAssertGreaterThan(midway.groundGain, resting.groundGain)

        let finished = resolve(settings: .default, transition: HorizonFrameResolver.handoverEnd, geometryTransition: 1, mode: .spherical)
        let switched = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 0)
        assertGroundSideEqual(finished, switched)
        XCTAssertEqual(finished.skyStrength, 0)
        XCTAssertEqual(finished.featherStrength, 0)
        XCTAssertFalse(finished.drawsSky)
    }

    func testTheHandoverIsContinuous() {
        var previous = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical)
        for step in 1...100 {
            let transition = Float(step) / 100
            let haze = resolve(settings: .default,
                               transition: transition,
                               geometryTransition: min(1, transition / 0.9),
                               mode: .spherical)
            XCTAssertLessThan(abs(haze.skyStrength - previous.skyStrength), 0.05, "sky at \(transition)")
            XCTAssertLessThan(abs(haze.groundGain - previous.groundGain), 0.05, "gain at \(transition)")
            XCTAssertLessThan(abs(haze.featherStrength - previous.featherStrength), 0.05, "feather at \(transition)")
            XCTAssertLessThan(simd_distance(haze.tint, previous.tint), 0.05, "tint at \(transition)")
            XCTAssertLessThan(abs(haze.groundBandRadians - previous.groundBandRadians), 0.05, "band at \(transition)")
            previous = haze
        }
    }

    // MARK: - The ground profile

    func testTheGroundProfileSaturatesAtTheLineAndDiesAtTheCutoff() {
        let haze = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: 0, haze: haze), 1)
        XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: haze.cutoffEndRadians, haze: haze), 0)
        var previous: Float = 1
        for step in 1...60 {
            let below = haze.cutoffEndRadians * Float(step) / 60
            let amount = HorizonFrameResolver.groundProfile(belowRadians: below, haze: haze)
            XCTAssertLessThanOrEqual(amount, previous + 1e-6, "the fog only thins away from the line")
            previous = amount
        }
    }

    // MARK: - Helpers

    private func fogColor(_ settings: ImmersiveMapSettings) -> SIMD3<Float> {
        SIMD3<Float>(Float(settings.scene.mapClearColor.x),
                     Float(settings.scene.mapClearColor.y),
                     Float(settings.scene.mapClearColor.z))
    }

    private func assertGroundSideEqual(_ a: HorizonHaze, _ b: HorizonHaze, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.groundGain, b.groundGain, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(a.groundBandRadians, b.groundBandRadians, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(a.cutoffStartRadians, b.cutoffStartRadians, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(a.cutoffEndRadians, b.cutoffEndRadians, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(simd_distance(a.tint, b.tint), 0, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(a.edge.depression, b.edge.depression, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(simd_distance(a.edge.up, b.edge.up), 0, accuracy: 1e-5, file: file, line: line)
    }

    /// The render camera of the offscreen harness: unit distance from the
    /// view centre, pitched about the x axis, a square viewport.
    private func resolve(settings: ImmersiveMapSettings,
                         transition: Float,
                         geometryTransition: Float,
                         mode: ViewMode,
                         pitch: Float = 0,
                         heightPx: Float = 200) -> HorizonHaze {
        let pitchRotation = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let eye = simd_act(pitchRotation, SIMD3<Float>(0, 0, 1))
        let up = simd_act(pitchRotation, SIMD3<Float>(0, 1, 0))
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4, aspect: 1, near: 0.01, far: 200)
        let view = Matrix.lookAt(eye: eye, center: SIMD3<Float>(0, 0, 0), up: up)
        return HorizonFrameResolver.resolve(settings: settings,
                                            transition: transition,
                                            globe: GlobeUniform(panX: 0, panY: 0, radius: radius, transition: geometryTransition),
                                            renderSurfaceMode: mode,
                                            cameraEye: eye,
                                            projectionView: projection * view,
                                            verticalFovRadians: .pi / 4,
                                            drawableHeightPx: heightPx)
    }
}

/// The uniform layout is a binding contract with `Horizon` in Horizon.metal:
/// same offsets, same 256-byte stride.
final class HorizonUniformLayoutTests: XCTestCase {
    func testLayoutMirrorsTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<HorizonUniform>.stride, 256)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.inverseViewProjection), 0)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.up), 64)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.depression), 80)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.center), 96)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.sunInfluence), 112)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.light), 128)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.skyStrength), 144)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.tint), 160)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.whitenWeight), 176)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.eye), 192)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.featherStrength), 208)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.bandRadians), 212)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.glowRadians), 216)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.whitenRadians), 220)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.featherRadians), 224)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.groundBandRadians), 228)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.groundGain), 232)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.cutoffStartRadians), 236)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.cutoffEndRadians), 240)
    }
}
