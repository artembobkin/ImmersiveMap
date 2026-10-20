// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The per-frame schedule of the horizon layer: the atmosphere on the
/// globe and along the unroll, the fog on the plane, and the air handover
/// between them at the end of the morph.
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
        let shell = radius * atmosphere.thickness.value(atZoom: 8) / limbDistance
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
        let ratio = 2 / ImmersiveMapSettings.default.scene.atmosphere.thickness.value(atZoom: 8)
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
    /// everything above the line and nothing on the ground. The far ground
    /// is the ground fog's, not the horizon's.
    func testThePlaneWearsTheSkyAndNothingOnTheGround() {
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
        XCTAssertEqual(haze.tint, fog.horizonColor, "The sky glows the horizon colour at the line")
        XCTAssertEqual(haze.skyColor, fog.skyColor)
        XCTAssertEqual(haze.skyOpacity, 1)
        XCTAssertEqual(haze.skyGradientRadians, HorizonFrameResolver.skyGradientRadians)
        XCTAssertEqual(haze.groundGain, 0, "Nothing is painted on the ground")
        XCTAssertTrue(haze.drawsSky, "The sky gradient paints everything above the line")
        XCTAssertFalse(haze.drawsGround, "The ground side is the globe's alone")
        XCTAssertGreaterThan(haze.bandTopRadians, HorizonFrameResolver.bandTopMarginRadians,
                             "The plane's band reaches past the top of the frame")
    }

    /// Off, nothing is painted at all on the plane: neither above the line
    /// nor on the ground.
    func testTheFogOffPaintsNothingOnThePlane() {
        let settings = ImmersiveMapSettings.default.fog(isEnabled: false)
        let haze = resolve(settings: settings, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(haze.skyOpacity, 0)
        XCTAssertEqual(haze.groundGain, 0)
        XCTAssertFalse(haze.drawsSky, "With the fog off nothing above the horizon is painted")
        XCTAssertFalse(haze.drawsGround)
    }

    /// The plane's treatment does not depend on the atmosphere switch.
    func testThePlaneIgnoresTheAtmosphereSwitch() {
        let on = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        let off = resolve(settings: .default.atmosphere(isEnabled: false), transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(on, off)
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

    /// The atmosphere rides the unrolling surface's edge: up to the air
    /// handover the halo, the rim, the sun's side and the feather are at
    /// the resting globe's strength, in the halo's own colour, with no sky
    /// from the flat map under them, and the widths are the growing
    /// sphere's, thinner every frame as its limb recedes.
    func testTheAtmosphereRidesTheUnroll() {
        let start = ImmersiveMapSettings.default.presentation.airHandoverStart
        let resting = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical, pitch: 1.25)
        var previousBand = resting.bandRadians
        for transition in [Float(0.2), 0.5, start] {
            let haze = resolve(settings: .default, transition: transition, geometryTransition: transition / 0.9, mode: .spherical, pitch: 1.25)
            XCTAssertEqual(haze.skyStrength, resting.skyStrength, "halo at \(transition)")
            XCTAssertEqual(haze.featherStrength, resting.featherStrength, "feather at \(transition)")
            XCTAssertEqual(haze.groundGain, resting.groundGain, "rim at \(transition)")
            XCTAssertEqual(haze.sunInfluence, resting.sunInfluence, "sun at \(transition)")
            XCTAssertEqual(haze.whitenWeight, resting.whitenWeight, "whitening at \(transition)")
            XCTAssertEqual(haze.tint, resting.tint, "The halo keeps its colour until the handover")
            XCTAssertEqual(haze.skyOpacity, 0, "No sky from the flat map before the handover")
            XCTAssertTrue(haze.drawsSky, "sky draw at \(transition)")
            XCTAssertTrue(haze.drawsGround, "ground draw at \(transition)")
            XCTAssertLessThan(haze.bandRadians, previousBand, "The halo thins as the limb recedes, at \(transition)")
            previousBand = haze.bandRadians
        }
    }

    /// Midway through the handover one frame carries both airs at their
    /// shares: the halo, the rim, the sun's side and the feather at half,
    /// the sky at half, the colour at the edge halfway from the halo's to
    /// the sky's at the line, and the band reaching the top of the frame
    /// for the sky.
    func testTheAirHandsOverAtTheEndOfTheMorph() {
        let settings = ImmersiveMapSettings.default
        let presentation = settings.presentation
        let atmosphere = settings.scene.atmosphere
        let fog = settings.scene.fog
        let midway = (presentation.airHandoverStart + presentation.airHandoverEnd) / 2
        let haze = resolve(settings: settings, transition: midway, geometryTransition: midway / 0.9, mode: .spherical, pitch: 1.25)
        XCTAssertEqual(haze.skyStrength, atmosphere.intensity / 2, accuracy: 1e-5)
        XCTAssertEqual(haze.groundGain, atmosphere.intensity / 2, accuracy: 1e-5)
        XCTAssertEqual(haze.featherStrength, HorizonFrameResolver.featherPeakStrength / 2, accuracy: 1e-5)
        XCTAssertEqual(haze.sunInfluence, atmosphere.sunInfluence / 2, accuracy: 1e-5)
        XCTAssertEqual(haze.whitenWeight, HorizonFrameResolver.haloWhitenWeight / 2, accuracy: 1e-5)
        XCTAssertEqual(haze.skyOpacity, 0.5, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(haze.tint, (atmosphere.color + fog.horizonColor) / 2), 0, accuracy: 1e-5)
        XCTAssertEqual(haze.skyColor, fog.skyColor)
        XCTAssertTrue(haze.drawsSky)
        XCTAssertTrue(haze.drawsGround)
        XCTAssertGreaterThan(haze.bandTopRadians, HorizonFrameResolver.bandTopMarginRadians,
                             "The band reaches past the top of the frame once the sky is in")

        // Transparent space withholds the halo under the arriving sky, and
        // keeps the feather.
        let transparent = resolve(settings: settings.transparentSpace(), transition: midway, geometryTransition: midway / 0.9, mode: .spherical, pitch: 1.25)
        XCTAssertEqual(transparent.skyStrength, 0)
        XCTAssertEqual(transparent.sunInfluence, 0)
        XCTAssertEqual(transparent.skyOpacity, 0.5, accuracy: 1e-5)
        XCTAssertEqual(transparent.featherStrength, haze.featherStrength)
        XCTAssertTrue(transparent.drawsSky, "The plane's sky arrives with the fade")
    }

    /// From the handover's end to the switch the sphere's path draws
    /// exactly the plane's values, and at 1 the surface switch happens
    /// between identical frames. With the fog off nothing fades in.
    func testTheHandedOverAirIsThePlanes() {
        let end = ImmersiveMapSettings.default.presentation.airHandoverEnd
        let fog = ImmersiveMapSettings.default.scene.fog
        let handedOver = resolve(settings: .default, transition: end, geometryTransition: 1, mode: .spherical, pitch: 1.25)
        XCTAssertEqual(handedOver.skyStrength, 0, "The halo is gone")
        XCTAssertEqual(handedOver.featherStrength, 0)
        XCTAssertEqual(handedOver.groundGain, 0, "Nothing on the ground")
        XCTAssertEqual(handedOver.skyOpacity, 1)
        XCTAssertEqual(handedOver.tint, fog.horizonColor)
        XCTAssertTrue(handedOver.drawsSky)
        XCTAssertFalse(handedOver.drawsGround)

        let finished = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .spherical, pitch: 1.25)
        let switched = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        XCTAssertEqual(handedOver, finished, "Nothing changes from the handover's end to the switch")
        assertGroundSideEqual(finished, switched)
        XCTAssertEqual(finished.skyOpacity, switched.skyOpacity)
        XCTAssertEqual(finished.drawsSky, switched.drawsSky)
        XCTAssertEqual(finished.bandTopRadians, switched.bandTopRadians, accuracy: 1e-5)

        let bareFinished = resolve(settings: .default.fog(isEnabled: false), transition: 1, geometryTransition: 1, mode: .spherical, pitch: 1.25)
        let bareSwitched = resolve(settings: .default.fog(isEnabled: false), transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        assertGroundSideEqual(bareFinished, bareSwitched)
        XCTAssertEqual(bareFinished.groundGain, 0)
        XCTAssertFalse(bareFinished.drawsSky)
        XCTAssertFalse(bareFinished.drawsGround)
    }

    /// The handover's bounds are the map's to set: an earlier, wider window
    /// hands over earlier.
    func testTheHandoverFollowsTheSettings() {
        let settings = ImmersiveMapSettings.default.globe(airHandoverStart: 0.3, airHandoverEnd: 0.5)
        let before = resolve(settings: settings, transition: 0.3, geometryTransition: 0.3 / 0.9, mode: .spherical, pitch: 1.25)
        let midway = resolve(settings: settings, transition: 0.4, geometryTransition: 0.4 / 0.9, mode: .spherical, pitch: 1.25)
        let after = resolve(settings: settings, transition: 0.5, geometryTransition: 0.5 / 0.9, mode: .spherical, pitch: 1.25)
        XCTAssertEqual(before.skyOpacity, 0)
        XCTAssertEqual(midway.skyOpacity, 0.5, accuracy: 1e-5)
        XCTAssertEqual(after.skyOpacity, 1)
        XCTAssertEqual(after.skyStrength, 0)
    }

    /// The handover is smooth: no frame of the transition jumps.
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
            XCTAssertLessThan(simd_distance(haze.tint, previous.tint), 0.05, "tint at \(transition)")
            previous = haze
        }
    }

    // MARK: - The ground profile

    /// The ground profile is the globe's rim: strongest at the limb, only
    /// thinning inward, and exactly nothing past its cutoff. On the plane
    /// it is nothing everywhere.
    func testTheGroundProfileIsTheRimsAndThePlaneHasNone() {
        let globe = resolve(settings: .default, transition: 0, geometryTransition: 0, mode: .spherical)
        XCTAssertGreaterThan(HorizonFrameResolver.groundProfile(belowRadians: 0, haze: globe), 0)
        XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: globe.cutoffEndRadians, haze: globe), 0)
        var previous = HorizonFrameResolver.groundProfile(belowRadians: 0, haze: globe)
        for step in 1...60 {
            let below = globe.cutoffEndRadians * Float(step) / 60
            let amount = HorizonFrameResolver.groundProfile(belowRadians: below, haze: globe)
            XCTAssertLessThanOrEqual(amount, previous + 1e-6, "the rim only thins away from the limb")
            previous = amount
        }
        let plane = resolve(settings: .default, transition: 1, geometryTransition: 1, mode: .flat, pitch: 1.25)
        for step in 0...10 {
            XCTAssertEqual(HorizonFrameResolver.groundProfile(belowRadians: Float(step) * 0.01, haze: plane), 0,
                           "Nothing is painted on the plane's ground")
        }
    }

    // MARK: - Helpers

    /// The band's colour with the fog off: the style's map colour, which
    /// every resolve here takes from the built-in theme unless stated.
    private func fogColor(_ settings: ImmersiveMapSettings) -> SIMD3<Float> {
        let map = ProtomapsBasemapTheme.default.baseColors.map
        return SIMD3<Float>(map.x, map.y, map.z)
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
                         mapColor: SIMD4<Float> = ProtomapsBasemapTheme.default.baseColors.map,
                         transition: Float,
                         geometryTransition: Float,
                         mode: ViewMode,
                         radius: Float? = nil,
                         pitch: Float = 0,
                         heightPx: Float = 200,
                         zoom: Double = 8) -> HorizonHaze {
        let radius = radius ?? self.radius
        let pitchRotation = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let eye = simd_act(pitchRotation, SIMD3<Float>(0, 0, 1))
        let up = simd_act(pitchRotation, SIMD3<Float>(0, 1, 0))
        let projection = Matrix.perspectiveMatrix(fovRadians: .pi / 4, aspect: 1, near: 0.01, far: 200)
        let view = Matrix.lookAt(eye: eye, center: SIMD3<Float>(0, 0, 0), up: up)
        return HorizonFrameResolver.resolve(settings: settings,
                                            mapColor: mapColor,
                                            transition: transition,
                                            zoom: zoom,
                                            globe: GlobeUniform(panX: 0, panY: 0, radius: radius, transition: geometryTransition),
                                            renderSurfaceMode: mode,
                                            cameraEye: eye,
                                            projectionView: projection * view,
                                            verticalFovRadians: .pi / 4,
                                            drawableHeightPx: heightPx)
    }
}

/// The air handover's clock (`PresentationSettings.airHandover`): the
/// share of the plane's air at a point of the transition.
final class AirHandoverTests: XCTestCase {
    func testTheHandoverIsASmoothstepOverItsWindow() {
        let presentation = ImmersiveMapSettings.PresentationSettings(automaticTransitionStartZoom: 6,
                                                                     automaticTransitionSpan: 1,
                                                                     globeRadiusScale: 1,
                                                                     airHandoverStart: 0.6,
                                                                     airHandoverEnd: 0.8)
        XCTAssertEqual(presentation.airHandover(atTransition: 0), 0)
        XCTAssertEqual(presentation.airHandover(atTransition: 0.6), 0)
        XCTAssertEqual(presentation.airHandover(atTransition: 0.65), 0.15625, accuracy: 1e-6)
        XCTAssertEqual(presentation.airHandover(atTransition: 0.7), 0.5, accuracy: 1e-6)
        XCTAssertEqual(presentation.airHandover(atTransition: 0.8), 1)
        XCTAssertEqual(presentation.airHandover(atTransition: 1), 1, "The plane's air at the switch")
    }

    func testTheDefaultsHandOverBeforeTheGeometryFinishes() {
        let presentation = ImmersiveMapSettings.default.presentation
        XCTAssertEqual(presentation.airHandoverStart, 0.7)
        XCTAssertEqual(presentation.airHandoverEnd, PresentationStateResolver.geometryCompletionPhase)
    }

    /// An end before the start is a step at the start, never a division
    /// by zero or a window running backwards.
    func testAnEmptyWindowIsAStep() {
        let presentation = ImmersiveMapSettings.PresentationSettings(automaticTransitionStartZoom: 6,
                                                                     automaticTransitionSpan: 1,
                                                                     globeRadiusScale: 1,
                                                                     airHandoverStart: 0.5,
                                                                     airHandoverEnd: 0.2)
        XCTAssertEqual(presentation.airHandover(atTransition: 0.49), 0)
        XCTAssertEqual(presentation.airHandover(atTransition: 0.51), 1)
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
                                            mapColor: ProtomapsBasemapTheme.default.baseColors.map,
                                            transition: 0,
                                            zoom: 2,
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
                                               mapColor: ProtomapsBasemapTheme.default.baseColors.map,
                                               transition: 0,
                                               zoom: 2,
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
