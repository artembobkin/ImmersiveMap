// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the horizon layer paints this frame, resolved once on the CPU from
/// the settings, the transition and the camera. Three things share the edge:
///
/// - **The atmosphere**, the globe's only: a dense band hugging the limb, a
///   wide faint glow into space, a whitening at the edge, and a narrow rim
///   decaying inward over the surface. Optional (`AtmosphereSettings`).
/// - **The limb feather**, always on the sphere: a glow a couple of pixels
///   wide across the analytic limb, half over the mesh edge and half over
///   space, which is what hides the tile mesh's chord polygon and the
///   one-sample-per-pixel staircase of the silhouette. Sized in pixels, so
///   it is the same at every zoom.
/// - **The fog**, the flat map's (`FogSettings`): the sky above the
///   horizon line, a glow of the horizon colour at the line decaying into
///   the sky colour over a few degrees, and below it the far ground veiled
///   toward the horizon colour by distance from the camera. The haze is stated in camera distances
///   and turned into two angles under the line per frame
///   (`HorizonEdgeMath.depression`), so the shader keeps its one angle
///   profile: fully veiled up to the far angle, thinning smoothly to
///   nothing at the near one, and the map under the camera stays
///   byte-clean. With the fog off nothing is painted above the line and
///   the ground keeps a thin band into the map's clear colour at it, so
///   the far range still meets the sky with no seam.
///
/// The three never share a frame. The resting globe wears the first two.
/// As the morph starts the atmosphere fades out, gone by
/// `atmosphereFadeOutEnd` of the semantic transition, and the unroll then
/// runs bare: no halo, no feather, no haze. Over the last stretch, from
/// `fogFadeInStart`, where the geometry is already a finished plane, the
/// flat map's sky and haze fade in, complete at 1, so the surface switch
/// happens between identical frames.
struct HorizonHaze: Equatable {
    var edge: HorizonEdgeMath.Edge
    /// The current sphere's centre, for the sun's side of the limb.
    var center: SIMD3<Float>
    var light: SIMD3<Float>
    var sunInfluence: Float
    var skyStrength: Float
    var tint: SIMD3<Float>
    var whitenWeight: Float
    var featherStrength: Float
    var bandRadians: Float
    var glowRadians: Float
    var whitenRadians: Float
    var featherRadians: Float
    var groundBandRadians: Float
    var groundGain: Float
    var cutoffStartRadians: Float
    var cutoffEndRadians: Float
    /// The plane's sky colour away from the line; `tint` is its colour at
    /// the line.
    var skyColor: SIMD3<Float>
    /// How much of the plane's sky gradient is painted over what nothing
    /// painted: 0 on the globe, fading in at the end of the morph, 1 on
    /// the plane with the fog on.
    var skyOpacity: Float
    /// The e-fold width, radians above the line, of the glow of the tint
    /// the sky decays out of into the sky colour.
    var skyGradientRadians: Float
    /// Whether the sky-side draw (pixels nothing painted) runs this frame.
    var drawsSky: Bool
    /// Whether the ground-side draw (painted pixels) runs this frame.
    var drawsGround: Bool
    /// The band's top station, radians above the edge: where the halo has
    /// decayed on the globe, the frame's highest corner plus a margin on
    /// the plane, whose sky is opaque all the way up.
    var bandTopRadians: Float
}

enum HorizonFrameResolver {
    /// The atmosphere fades out over the first stretch of the semantic
    /// transition and is gone by here.
    static let atmosphereFadeOutEnd: Float = 0.12
    /// The fog fades in from here to 1. The unroll finishes at 0.9
    /// (`PresentationStateResolver.geometryCompletionPhase`), so the fade
    /// plays over a finished plane and the plane's own values are reached
    /// exactly at the surface switch.
    static let fogFadeInStart: Float = 0.9

    /// The atmosphere's widths, in radii of the resting planet, seen from
    /// the eye as angle at the limb: the shell is a fixed fraction of the
    /// planet, thin from far away, wide when the eye is low over it.
    static let haloBandRadii: Float = 0.075
    static let haloGlowRadii: Float = 0.34
    static let haloWhitenRadii: Float = 0.018
    static let haloRimRadii: Float = 0.025
    static let haloWhitenWeight: Float = 0.5
    /// The rim over the surface fades out between these many rim widths
    /// under the limb and is exactly zero past the second.
    static let rimCutoffStartWidths: Float = 3
    static let rimCutoffEndWidths: Float = 6
    /// An eye almost touching the sphere would otherwise blow the halo up
    /// to the whole sky.
    static let maximumHaloRadians: Float = 45 * .pi / 180

    /// The seam-hiding band of the plane with the fog off, radians below
    /// the horizon: one exponential with a gain above one so it saturates
    /// to the clear colour at the line, cut off smoothly a few degrees
    /// under it.
    static let fogBandRadians: Float = 1.2 * .pi / 180
    static let fogGain: Float = 1.6
    static let fogCutoffStartRadians: Float = 4 * .pi / 180
    static let fogCutoffEndRadians: Float = 6 * .pi / 180

    /// The haze with the fog on rides the same profile with its exponential
    /// held saturated: the band is `hazeBandCutoffWidths` times the near
    /// cutoff angle and the gain covers the decay over that angle
    /// (`exp(1 / widths) = 1.65 < hazeGain`), so the profile is exactly the
    /// cutoff's smooth ramp: 1 up to the far angle, 0 from the near one.
    static let hazeBandCutoffWidths: Float = 2
    static let hazeGain: Float = 1.7
    /// The floor of the haze range, camera distances: nearer than this the
    /// haze would sit under the camera.
    static let minimumHazeStart: Float = 0.25
    /// The e-fold width, radians above the line, of the plane's horizon
    /// glow: the sky is the horizon colour at the line and the sky colour
    /// a few of these widths up.
    static let skyGradientRadians: Float = 2.5 * .pi / 180
    /// How far past the frame's highest corner the plane's band reaches, so
    /// the sky never ends inside the frame.
    static let bandTopMarginRadians: Float = 5 * .pi / 180
    /// The globe's band ends where the glow has decayed to under a percent.
    static let bandTopGlowWidths: Float = 5

    /// The limb feather: its e-fold width in pixels and its peak coverage.
    static let featherPixels: Float = 1.5
    static let featherPeakStrength: Float = 0.85

    /// Widths are e-fold denominators in the shader; a zero would divide.
    static let minimumRadians: Float = 1e-4

    /// How much of the atmosphere is left: 1 on the resting globe, 0 from
    /// `atmosphereFadeOutEnd` on and on the plane.
    static func atmosphereFade(transition: Float, renderSurfaceMode: ViewMode) -> Float {
        guard renderSurfaceMode == .spherical else { return 0 }
        let t = simd_clamp(transition / atmosphereFadeOutEnd, 0, 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// How much of the flat map's sky and haze is in: 0 before
    /// `fogFadeInStart`, 1 at the end of the transition and on the plane.
    static func fogFade(transition: Float, renderSurfaceMode: ViewMode) -> Float {
        guard renderSurfaceMode == .spherical else { return 1 }
        let t = simd_clamp((transition - fogFadeInStart) / (1 - fogFadeInStart), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// - Parameters:
    ///   - transition: the semantic transition (the fades' clock).
    ///   - globe: the geometry transition and the resting radius.
    ///   - verticalFovRadians: the render camera's vertical field of view,
    ///     which with the drawable height sizes the feather in pixels.
    static func resolve(settings: ImmersiveMapSettings,
                        transition: Float,
                        globe: GlobeUniform,
                        renderSurfaceMode: ViewMode,
                        cameraEye: SIMD3<Float>,
                        projectionView: matrix_float4x4,
                        verticalFovRadians: Float,
                        drawableHeightPx: Float) -> HorizonHaze {
        let atmosphere = settings.scene.atmosphere
        let isOn = atmosphere.isEnabled
        let fog = settings.scene.fog
        let radius = max(globe.radius, 1e-6)
        let curvature = renderSurfaceMode == .spherical
            ? max(1 - min(max(globe.transition, 0), 1), 0) / radius
            : 0
        let edge = HorizonEdgeMath.edge(eye: cameraEye, curvature: curvature)
        let atmosphereFade = atmosphereFade(transition: transition, renderSurfaceMode: renderSurfaceMode)
        let fogFade = fogFade(transition: transition, renderSurfaceMode: renderSurfaceMode)
        // The two fades never overlap, so a frame is either the globe's
        // (its atmosphere at some strength, or nothing) or the plane's.
        let showsFog = fogFade > 0
        let thickness = max(atmosphere.thickness, 0.05)
        let intensity = max(atmosphere.intensity, 0)

        // A shell of `radii` planet radii subtends `radii * R / limbDistance`
        // at the limb; infinite limb distance (the plane) gives zero.
        func haloRadians(_ radii: Float) -> Float {
            max(min(radii * radius * thickness / edge.limbDistance, maximumHaloRadians), minimumRadians)
        }

        let clearColor = SIMD3<Float>(Float(settings.scene.mapClearColor.x),
                                      Float(settings.scene.mapClearColor.y),
                                      Float(settings.scene.mapClearColor.z))
        let planeTint = fog.isEnabled ? fog.horizonColor : clearColor
        let globeTint = isOn ? atmosphere.color : clearColor
        let tint = showsFog ? planeTint : globeTint

        let inverseProjectionView = simd_inverse(projectionView)
        // The plane's haze: its camera-distance range becomes two angles
        // under the line for this frame's pitch (the centre ray's dip under
        // the local horizontal), the far one where the veil is complete and
        // the near one where it is gone.
        let centerDirection = HorizonEdgeMath.viewDirection(ndc: SIMD2<Float>(0, 0),
                                                            inverseProjectionView: inverseProjectionView,
                                                            eye: cameraEye)
        let cosPitch = max(-simd_dot(centerDirection, edge.up), 0)
        let hazeStart = max(fog.hazeRange.lowerBound, minimumHazeStart)
        let hazeEnd = max(fog.hazeRange.upperBound, hazeStart + minimumHazeStart)
        let planeCutoffStart = fog.isEnabled
            ? max(HorizonEdgeMath.depression(atCameraDistances: hazeEnd, cosPitch: cosPitch), minimumRadians)
            : fogCutoffStartRadians
        let planeCutoffEnd = fog.isEnabled
            ? max(HorizonEdgeMath.depression(atCameraDistances: hazeStart, cosPitch: cosPitch),
                  planeCutoffStart + minimumRadians)
            : fogCutoffEndRadians
        let planeBand = fog.isEnabled ? planeCutoffEnd * hazeBandCutoffWidths : fogBandRadians
        let planeGain = fog.isEnabled ? hazeGain : fogGain

        let rimRadians = haloRadians(haloRimRadii)
        let featherRadians = max(featherPixels * verticalFovRadians / max(drawableHeightPx, 1), minimumRadians)
        let featherStrength = featherPeakStrength * atmosphereFade
        let groundGain = showsFog ? planeGain * fogFade : (isOn ? intensity : 0) * atmosphereFade
        let groundBandRadians = max(showsFog ? planeBand : rimRadians, minimumRadians)
        let cutoffStartRadians = max(showsFog ? planeCutoffStart : rimRadians * rimCutoffStartWidths, minimumRadians)
        let cutoffEndRadians = max(showsFog ? planeCutoffEnd : rimRadians * rimCutoffEndWidths, minimumRadians)
        let skyOpacity = fog.isEnabled ? fogFade : 0

        let lightDirection = settings.scene.light.direction
        let light = simd_length_squared(lightDirection) > 1e-12
            ? simd_normalize(lightDirection)
            : SIMD3<Float>(0, 0, 1)

        let reach = max(cutoffEndRadians, featherRadians * 4)
        let cornerAngles = HorizonEdgeMath.cornerDirections(inverseProjectionView: inverseProjectionView,
                                                            eye: cameraEye)
            .map { HorizonEdgeMath.angleAboveEdge(direction: $0, edge: edge) }
        let edgeWithinReach = cornerAngles.contains { $0 >= -reach }
        // The band's top: the plane's sky is opaque to the top of the frame,
        // the globe's halo is done a few glow widths up.
        let frameTop = (cornerAngles.max() ?? 0) + bandTopMarginRadians
        let bandTopRadians = showsFog
            ? max(frameTop, skyGradientRadians * bandTopGlowWidths)
            : haloRadians(haloGlowRadii) * bandTopGlowWidths
        // Transparent space keeps the sphere unpainted around the planet:
        // no halo there, and the plane's sky arrives with the fade only.
        let drawsHalo = renderSurfaceMode == .spherical
            && settings.scene.space.isTransparent == false
            && atmosphereFade > 0
        let drawsSky = edgeWithinReach && (drawsHalo || skyOpacity > 0)
        let drawsGround = edgeWithinReach && (groundGain > 0 || featherStrength > 0)

        return HorizonHaze(edge: edge,
                           center: curvature > 0 ? SIMD3<Float>(0, 0, -1 / curvature) : SIMD3<Float>(0, 0, -1e6),
                           light: light,
                           sunInfluence: isOn ? min(max(atmosphere.sunInfluence, 0), 1) * atmosphereFade : 0,
                           skyStrength: isOn ? intensity * atmosphereFade : 0,
                           tint: tint,
                           whitenWeight: isOn ? haloWhitenWeight * atmosphereFade : 0,
                           featherStrength: featherStrength,
                           bandRadians: haloRadians(haloBandRadii),
                           glowRadians: haloRadians(haloGlowRadii),
                           whitenRadians: haloRadians(haloWhitenRadii),
                           featherRadians: featherRadians,
                           groundBandRadians: groundBandRadians,
                           groundGain: groundGain,
                           cutoffStartRadians: cutoffStartRadians,
                           cutoffEndRadians: cutoffEndRadians,
                           skyColor: fog.skyColor,
                           skyOpacity: skyOpacity,
                           skyGradientRadians: skyGradientRadians,
                           drawsSky: drawsSky,
                           drawsGround: drawsGround,
                           bandTopRadians: bandTopRadians)
    }

    /// CPU mirror of the shader's ground-side profile (`horizonGroundProfile`),
    /// before the feather: how much haze covers a painted pixel this far below
    /// the edge.
    static func groundProfile(belowRadians: Float, haze: HorizonHaze) -> Float {
        let amount = min(max(exp(-belowRadians / haze.groundBandRadians) * haze.groundGain, 0), 1)
        let t = min(max((belowRadians - haze.cutoffStartRadians)
                        / max(haze.cutoffEndRadians - haze.cutoffStartRadians, 1e-6), 0), 1)
        return amount * (1 - t * t * (3 - 2 * t))
    }
}
