// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The per-frame schedule of the horizon layer: the atmosphere on the
/// resting globe, the fog on the plane, and the two fades around the morph.
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
        XCTAssertEqual(haze.bandTopRadians, haze.glowRadians * HorizonFrameResolver.bandTopGlowWidths, accuracy: 1e-6,
                       "The globe's band ends where the glow has decayed")

        // The shell as a fraction of the planet, scaled by the thickness,
        // seen as angle at the limb.
        let centerDistance = 1 + radius
        let limbDistance = (centerDistance * centerDistance - radius * radius).squareRoot()
        let shell = radius * atmosphere.thickness / limbDistance
        XCTAssertEqual(haze.bandRadians, HorizonFrameResolver.haloBandRadii * shell, accuracy: 1e-5)
        XCTAssertEqual(haze.glowRadians, HorizonFrameResolver.haloGlowRadii * shell, accuracy: 1e-5)
        XCTAssertEqual(haze.groundBandRadians, HorizonFrameResolver.haloRimRadii * shell, accuracy: 1e-5)
        XCTAssertEqual(haze.cutoffStartRadians, haze.groundBandRadians * HorizonFrameResolver.rimCutoffStartWidths, accuracy: 1e-5)
        XCTAssertEqual(haze.cutoffEndRadians, haze.groundBandRadians * HorizonFrameResolver.rimCutoffEndWidths, accuracy: 1e-5)
    }

    func testThicknessStretchesTheHalo() {
        var settings = ImmersiveMapSettings.default
        settings.scene.atmosphere.thickness = 2
        let thick = resolve(settings: settings, transition: 0, geometryTransition: 0, mode: .spherical)
        let shipped = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical)
        let ratio = 2 / ImmersiveMapSettings.default.scene.atmosphere.thickness
        XCTAssertEqual(thick.bandRadians, shipped.bandRadians * ratio, accuracy: 1e-5)
        XCTAssertEqual(thick.glowRadians, shipped.glowRadians * ratio, accuracy: 1e-5)
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

    /// The fog is on by default: the plane paints the sky gradient over
    /// everything above the line and veils the far ground toward the
    /// horizon colour, with its two angles set from the camera-distance
    /// range for the frame's pitch.
    func testThePlaneWearsTheSkyAndTheHaze() {
        let settings = ImmersiveMapSettings.default
        let fog = settings.scene.fog
        XCTAssertTrue(fog.isEnabled, "The fog ships on")
        let pitch: Float = 1.25
        let haze = resolve(settings: settings, transition: 1, geometryTransition: 1, mode: .flat, pitch: pitch)
        XCTAssertEqual(haze.edge.depression, 0)
        XCTAssertEqual(haze.edge.up, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(haze.skyStrength, 0)
        XCTAssertEqual(haze.featherStrength, 0)
        XCTAssertEqual(haze.whitenWeight, 0, "No limb whitening on the plane: the sky brightens into the line on its own")
        XCTAssertEqual(haze.sunInfluence, 0)
        XCTAssertEqual(haze.tint, fog.horizonColor, "The haze veils toward the horizon colour")
        XCTAssertEqual(haze.skyColor, fog.skyColor)
        XCTAssertEqual(haze.skyOpacity, 1)
        XCTAssertEqual(haze.skyGradientRadians, HorizonFrameResolver.skyGradientRadians)
        XCTAssertEqual(haze.groundGain, HorizonFrameResolver.hazeGain, accuracy: 1e-6)
        // The camera looks down at the ground `cos(pitch)` camera distances
        // below it, so the range's ends are angles under the line.
        let farAngle = asin(cos(pitch) / fog.hazeRange.upperBound)
        let nearAngle = asin(cos(pitch) / fog.hazeRange.lowerBound)
        XCTAssertEqual(haze.cutoffStartRadians, farAngle, accuracy: 1e-5)
        XCTAssertEqual(haze.cutoffEndRadians, nearAngle, accuracy: 1e-5)
        XCTAssertEqual(haze.groundBandRadians, nearAngle * HorizonFrameResolver.hazeBandCutoffWidths, accuracy: 1e-5)
        XCTAssertTrue(haze.drawsSky, "The sky gradient paints everything above the line")
        XCTAssertTrue(haze.drawsGround, "Pitched almost to the horizon, the haze is in the frame")
        XCTAssertGreaterThan(haze.bandTopRadians, HorizonFrameResolver.bandTopMarginRadians,
                             "The plane's band reaches past the top of the frame")
    }

    /// The haze follows the camera: a lower pitch puts the same camera
    /// distances at steeper angles under the line, and looking straight
    /// down the near end of the range is the nadir itself.
    func testTheHazeAnglesFollowThePitch() {
        let high = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        let low = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 0.8)
        XCTAssertGreaterThan(low.cutoffStartRadians, high.cutoffStartRadians)
        XCTAssertGreaterThan(low.cutoffEndRadians, high.cutoffEndRadians)
        var settings = ImmersiveMapSettings.default
        settings.scene.fog.hazeRange = 0.5...4
        let nadir = resolve(settings: settings, transition: 1, geometryTransition: 1, mode: .flat, pitch: 0)
        XCTAssertEqual(nadir.cutoffEndRadians, .pi / 2, accuracy: 1e-5, "Nearer than the eye's height is the nadir")
    }

    /// Nearer than the near end of the range the haze is exactly nothing,
    /// farther than the far end it is complete: the profile is the cutoff's
    /// own ramp, with the exponential held saturated across it.
    func testTheHazeIsCompleteBeyondTheRangeAndAbsentInsideIt() {
        let haze = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: 0, haze: haze), 1)
        XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: haze.cutoffStartRadians, haze: haze), 1)
        XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: haze.cutoffEndRadians, haze: haze), 0)
        XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: haze.cutoffEndRadians * 2, haze: haze), 0)
        XCTAssertGreaterThan(HorizonFrameResolver.hazeGain, exp(1 / HorizonFrameResolver.hazeBandCutoffWidths),
                             "The gain covers the exponential's decay over the near cutoff angle")
    }

    /// Off, the plane is what it was before the fog: nothing painted above
    /// the line, and a thin band into the clear colour at it.
    func testTheFogOffKeepsOnlyTheSeamBand() {
        let settings = ImmersiveMapSettings.default.fog(isEnabled: false)
        let haze = resolve(settings: settings, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(haze.tint, fogColor(settings))
        XCTAssertEqual(haze.skyOpacity, 0)
        XCTAssertEqual(haze.groundGain, HorizonFrameResolver.fogGain, accuracy: 1e-6)
        XCTAssertEqual(haze.groundBandRadians, HorizonFrameResolver.fogBandRadians, accuracy: 1e-6)
        XCTAssertEqual(haze.cutoffStartRadians, HorizonFrameResolver.fogCutoffStartRadians, accuracy: 1e-6)
        XCTAssertEqual(haze.cutoffEndRadians, HorizonFrameResolver.fogCutoffEndRadians, accuracy: 1e-6)
        XCTAssertFalse(haze.drawsSky, "With the fog off nothing above the horizon is painted")
        XCTAssertTrue(haze.drawsGround, "Pitched almost to the horizon, the band is in the frame")
    }

    /// The plane's treatment does not depend on the atmosphere switch.
    func testTheFogBandIsRequired() {
        let on = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        let off = resolve(settings: .default.atmosphere(isEnabled: false), transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(on, off)
    }

    /// With the fog off the band's colour is the map's clear colour, so the
    /// ground meets the sky above the line in one colour.
    func testTheSeamBandColourFollowsTheClearColour() {
        var settings = ImmersiveMapSettings.default.fog(isEnabled: false)
        settings.scene.mapClearColor = SIMD4<Double>(0.1, 0.5, 0.9, 1)
        let haze = resolve(settings: settings, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(haze.tint, SIMD3<Float>(0.1, 0.5, 0.9))
    }

    /// The flat map is opaque under transparent space, so its sky still
    /// paints; only the globe's halo is withheld.
    func testTransparentSpaceKeepsThePlanesSky() {
        let haze = resolve(settings: .default.transparentSpace(), transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertTrue(haze.drawsSky)
    }

    /// Looking down at street pitch, the horizon is far outside the frame
    /// and the layer draws nothing at all.
    func testALowPitchSkipsBothDraws() {
        let haze = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 0.3)
        XCTAssertFalse(haze.drawsSky)
        XCTAssertFalse(haze.drawsGround)
    }

    // MARK: - The morph

    /// The atmosphere fades out over the first stretch of the transition
    /// and is gone well before the surface has unrolled far; nothing of the
    /// flat map's sky comes in with it.
    func testTheAtmosphereFadesOutAsTheMorphStarts() {
        let end = HorizonFrameResolver.atmosphereFadeOutEnd
        let resting = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical, pitch: 1.25)
        let halfway = resolve(settings: .default, transition: end / 2, geometryTransition: end / 2 / 0.9, mode: .spherical, pitch: 1.25)
        XCTAssertGreaterThan(halfway.skyStrength, 0)
        XCTAssertLessThan(halfway.skyStrength, resting.skyStrength)
        XCTAssertLessThan(halfway.featherStrength, resting.featherStrength)
        XCTAssertLessThan(halfway.groundGain, resting.groundGain)
        XCTAssertEqual(halfway.tint, resting.tint, "The halo keeps its colour while it fades")
        XCTAssertEqual(halfway.skyOpacity, 0, "No sky from the flat map on the sphere")

        let gone = resolve(settings: .default, transition: end, geometryTransition: end / 0.9, mode: .spherical, pitch: 1.25)
        XCTAssertEqual(gone.skyStrength, 0)
        XCTAssertEqual(gone.featherStrength, 0)
        XCTAssertEqual(gone.groundGain, 0)
        XCTAssertFalse(gone.drawsSky)
        XCTAssertFalse(gone.drawsGround)
    }

    /// Between the two fades the unroll runs bare: the layer draws nothing.
    func testTheMorphRunsWithoutAir() {
        for transition in [Float(0.2), 0.5, 0.85] {
            let haze = resolve(settings: .default, transition: transition, geometryTransition: min(1, transition / 0.9), mode: .spherical, pitch: 1.0)
            XCTAssertFalse(haze.drawsSky, "sky at \(transition)")
            XCTAssertFalse(haze.drawsGround, "ground at \(transition)")
            XCTAssertEqual(haze.skyOpacity, 0, "sky opacity at \(transition)")
        }
    }

    /// The fog fades in over the last stretch, where the geometry is
    /// already a finished plane, and at 1 the sphere path renders exactly
    /// the plane's values, so the surface switch happens between identical
    /// frames. With the fog off it is the seam band that fades in.
    func testTheFogFadesInAtTheEndOfTheMorph() {
        let fog = ImmersiveMapSettings.default.scene.fog
        let midway = resolve(settings: .default, transition: 0.95, geometryTransition: 1, mode: .spherical, pitch: 1.25)
        XCTAssertGreaterThan(midway.skyOpacity, 0)
        XCTAssertLessThan(midway.skyOpacity, 1)
        XCTAssertGreaterThan(midway.groundGain, 0)
        XCTAssertLessThan(midway.groundGain, HorizonFrameResolver.hazeGain)
        XCTAssertEqual(midway.tint, fog.horizonColor)
        XCTAssertEqual(midway.skyStrength, 0, "The halo is long gone")
        XCTAssertEqual(midway.featherStrength, 0)
        XCTAssertTrue(midway.drawsSky)

        let finished = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .spherical, pitch: 1.25)
        let switched = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        assertGroundSideEqual(finished, switched)
        XCTAssertEqual(finished.skyOpacity, 1)
        XCTAssertEqual(finished.skyOpacity, switched.skyOpacity)
        XCTAssertEqual(finished.drawsSky, switched.drawsSky)

        let bareFinished = resolve(settings: .default.fog(isEnabled: false), transition: 1, geometryTransition: 1, mode: .spherical, pitch: 1.25)
        let bareSwitched = resolve(settings: .default.fog(isEnabled: false), transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        assertGroundSideEqual(bareFinished, bareSwitched)
        XCTAssertEqual(bareFinished.groundGain, HorizonFrameResolver.fogGain, accuracy: 1e-6)
        XCTAssertFalse(bareFinished.drawsSky)
    }

    /// Both fades are smooth: no frame of the transition jumps.
    func testTheFadesAreContinuous() {
        var previous = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical, pitch: 1.25)
        for step in 1...1000 {
            let transition = Float(step) / 1000
            let haze = resolve(settings: .default,
                               transition: transition,
                               geometryTransition: min(1, transition / 0.9),
                               mode: .spherical,
                               pitch: 1.25)
            XCTAssertLessThan(abs(haze.skyStrength - previous.skyStrength), 0.05, "sky at \(transition)")
            XCTAssertLessThan(abs(haze.groundGain - previous.groundGain), 0.05, "gain at \(transition)")
            XCTAssertLessThan(abs(haze.featherStrength - previous.featherStrength), 0.05, "feather at \(transition)")
            XCTAssertLessThan(abs(haze.skyOpacity - previous.skyOpacity), 0.05, "sky opacity at \(transition)")
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
                         radius: Float? = nil,
                         pitch: Float = 0,
                         heightPx: Float = 200) -> HorizonHaze {
        let radius = radius ?? self.radius
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
/// same offsets, same stride.
final class HorizonUniformLayoutTests: XCTestCase {
    func testLayoutMirrorsTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<HorizonUniform>.stride, 304)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.up), 0)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.depression), 16)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.center), 32)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.sunInfluence), 48)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.light), 64)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.skyStrength), 80)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.tint), 96)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.whitenWeight), 112)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.eye), 128)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.featherStrength), 144)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.bandRadians), 148)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.glowRadians), 152)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.whitenRadians), 156)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.featherRadians), 160)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.groundBandRadians), 164)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.groundGain), 168)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.cutoffStartRadians), 172)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.cutoffEndRadians), 176)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.skyColor), 192)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.skyOpacity), 208)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.skyGradientRadians), 212)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.viewProjection), 224)
        XCTAssertEqual(MemoryLayout<HorizonUniform>.offset(of: \.bandTopRadians), 288)
    }
}

/// The globe's band: its stations, mirrored from the shader, cover the
/// profile's support in order.
final class HorizonBandMathTests: XCTestCase {
    private let radius: Float = 0.28

    private func restingHaze(heightPx: Float = 2000) -> HorizonHaze {
        let eye = SIMD3<Float>(0, 0, 1)
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4, aspect: 1, near: 0.01, far: 200)
        let view = Matrix.lookAt(eye: eye, center: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0))
        return HorizonFrameResolver.resolve(settings: .default,
                                            transition: 0,
                                            globe: GlobeUniform(panX: 0, panY: 0, radius: radius, transition: 0),
                                            renderSurfaceMode: .spherical,
                                            cameraEye: eye,
                                            projectionView: projection * view,
                                            verticalFovRadians: .pi / 4,
                                            drawableHeightPx: heightPx)
    }

    func testTheStationsRunFromTheRimsEndToFiveGlowWidths() {
        let haze = restingHaze()
        let angles = HorizonBandMath.stationAngles(haze: haze)
        XCTAssertEqual(angles.count, HorizonBandMath.stationCount)
        XCTAssertEqual(angles.first, -haze.cutoffEndRadians, "Under the limb the band ends where the rim does")
        XCTAssertEqual(angles.last, haze.bandTopRadians, "Over the limb it ends where the resolver put the top")
        XCTAssertTrue(angles.contains(0), "The limb itself is a station")
        XCTAssertGreaterThanOrEqual(angles[4], haze.featherRadians * 4, "The feather's ramp gets its own quads")
    }

    /// Low over the planet the glow is capped at 45 degrees; five of those
    /// would pass the zenith, so the outer station stops just under it.
    func testTheStationsStayOnTheSphereOfDirections() {
        let eye = SIMD3<Float>(0, 0, 1)
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4, aspect: 1, near: 0.01, far: 200)
        let view = Matrix.lookAt(eye: eye, center: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0))
        let low = HorizonFrameResolver.resolve(settings: .default,
                                               transition: 0,
                                               globe: GlobeUniform(panX: 0, panY: 0, radius: 200, transition: 0),
                                               renderSurfaceMode: .spherical,
                                               cameraEye: eye,
                                               projectionView: projection * view,
                                               verticalFovRadians: .pi / 4,
                                               drawableHeightPx: 2000)
        XCTAssertEqual(low.glowRadians, HorizonFrameResolver.maximumHaloRadians, accuracy: 1e-6, "The cap is in force this low")
        let angles = HorizonBandMath.stationAngles(haze: low)
        XCTAssertLessThan(angles.last ?? .infinity, low.edge.depression + .pi / 2, "The outer station stays under the zenith")
        XCTAssertGreaterThan(angles.first ?? -.infinity, low.edge.depression - .pi / 2)
        for (previous, next) in zip(angles, angles.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next)
        }
    }

    func testTheStationsStayInOrderOnASmallDrawable() {
        // A 100 px drawable makes four feather widths wider than the rim's
        // cutoffs at this distance; the running maximum keeps the order.
        for heightPx in [Float(100), 200, 2000] {
            let angles = HorizonBandMath.stationAngles(haze: restingHaze(heightPx: heightPx))
            for (previous, next) in zip(angles, angles.dropFirst()) {
                XCTAssertLessThanOrEqual(previous, next, "\(heightPx) px")
            }
        }
    }
}
