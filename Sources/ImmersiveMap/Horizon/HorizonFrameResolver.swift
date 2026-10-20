// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the horizon layer paints this frame, resolved once on the CPU from
/// the settings, the transition and the camera. Three things share the edge:
///
/// - **The atmosphere**, the globe's: a dense band hugging the limb, a
///   wide faint glow into space, a whitening at the edge, and a narrow rim
///   decaying inward over the surface. Optional (`AtmosphereSettings`).
/// - **The limb feather**, always on the sphere: a glow a couple of pixels
///   wide across the analytic limb, half over the mesh edge and half over
///   space, which is what hides the tile mesh's chord polygon and the
///   one-sample-per-pixel staircase of the silhouette. Sized in pixels, so
///   it is the same at every zoom.
/// - **The sky**, the flat map's (`FogSettings`): above the horizon
///   line, a glow of the horizon colour at the line decaying into the sky
///   colour over a few degrees. Nothing is painted on the ground: the far
///   ground is the ground fog's (`GroundFogSettings`), drawn by the
///   shaders of what stands on the map by its distance, which veils it
///   into the sky's colour where it meets the line. An angle profile under
///   the line would be wrong there anyway: the ground relief's silhouette
///   is not the plane's line, a near slope lying under it and a peak over
///   it. With the fog off nothing is painted above the line either.
///
/// The resting globe wears the first two, and so does the unrolling
/// surface: its edge is the limb of the growing sphere the unroll keeps
/// the surface on (`HorizonEdgeMath`), and the halo rides it, thinning on
/// its own as that limb recedes (its widths are angles at the limb). Over
/// the air handover (`PresentationSettings.airHandoverStart` to
/// `airHandoverEnd`) the atmosphere and the feather fade out while the
/// flat map's sky fades in under them, the halo's colour turning into the
/// sky's colour at the line, so one frame carries both at their shares. The
/// handover ends by default where the geometry is a finished plane, and
/// from there to the surface switch at 1 the sphere's path draws exactly
/// the plane's values, so the switch happens between identical frames.
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

/// The `Horizon` folder: the CPU-side model of the surface's visible edge and
/// the air painted around it, the maths and the per-frame decisions, with the
/// shader's edge angle mirrored bit for bit so tests agree with the picture,
/// and the band mesh, the pipeline, the uniform and the shader that draw
/// it. No tile or style logic, no camera controllers or UI.
enum HorizonFrameResolver {
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

    /// How much of the atmosphere is left: 1 on the resting globe and up
    /// to the air handover, 0 from its end on and on the plane.
    static func atmosphereFade(transition: Float,
                               presentation: ImmersiveMapSettings.PresentationSettings,
                               renderSurfaceMode: ViewMode) -> Float {
        guard renderSurfaceMode == .spherical else { return 0 }
        return 1 - presentation.airHandover(atTransition: transition)
    }

    /// How much of the flat map's sky is in: 0 up to the air handover, 1
    /// from its end on and on the plane. The two fades sum to one, so a
    /// frame of the handover carries both at their shares.
    static func fogFade(transition: Float,
                        presentation: ImmersiveMapSettings.PresentationSettings,
                        renderSurfaceMode: ViewMode) -> Float {
        guard renderSurfaceMode == .spherical else { return 1 }
        return presentation.airHandover(atTransition: transition)
    }

    /// - Parameters:
    ///   - transition: the semantic transition (the handover's clock).
    ///   - zoom: the camera zoom, the band zoom fade's clock.
    ///   - globe: the geometry transition and the resting radius.
    ///   - verticalFovRadians: the render camera's vertical field of view,
    ///     which with the drawable height sizes the feather in pixels.
    static func resolve(settings: ImmersiveMapSettings,
                        mapColor: SIMD4<Float>,
                        transition: Float,
                        zoom: Double,
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
        let presentation = settings.presentation
        let atmosphereFade = atmosphereFade(transition: transition,
                                            presentation: presentation,
                                            renderSurfaceMode: renderSurfaceMode)
        let fogFade = fogFade(transition: transition,
                              presentation: presentation,
                              renderSurfaceMode: renderSurfaceMode)
        // The halo's width at the camera zoom, floored: a shell of nothing
        // would put the feather and the rim at the same angle.
        let thickness = max(atmosphere.thickness.value(atZoom: zoom), 0.05)
        let intensity = max(atmosphere.intensity, 0)

        // A shell of `radii` planet radii subtends `radii * R / limbDistance`
        // at the limb; infinite limb distance (the plane) gives zero. On
        // the unrolling surface the limb is the growing sphere's, farther
        // every frame, so the halo thins on its own as the planet
        // flattens.
        func haloRadians(_ radii: Float) -> Float {
            max(min(radii * radius * thickness / edge.limbDistance, maximumHaloRadians), minimumRadians)
        }

        let clearColor = SIMD3<Float>(mapColor.x, mapColor.y, mapColor.z)
        let planeTint = fog.isEnabled ? fog.horizonColor : clearColor
        let globeTint = isOn ? atmosphere.color : clearColor
        // The colour at the edge, the halo's turning into the sky's at the
        // line through the handover, so the two meet in one colour.
        let tint = globeTint + (planeTint - globeTint) * fogFade

        let inverseProjectionView = simd_inverse(projectionView)
        // The ground side is the globe's alone: the rim of the atmosphere
        // decaying inward over the surface, and the limb feather, both
        // fading out through the handover. The plane paints nothing on
        // the ground, and its rim's widths are the floor: an infinite
        // limb distance.
        let rimRadians = haloRadians(haloRimRadii)
        let featherRadians = max(featherPixels * verticalFovRadians / max(drawableHeightPx, 1), minimumRadians)
        let featherStrength = featherPeakStrength * atmosphereFade
        let groundGain = (isOn ? intensity : 0) * atmosphereFade
        let groundBandRadians = max(rimRadians, minimumRadians)
        let cutoffStartRadians = max(rimRadians * rimCutoffStartWidths, minimumRadians)
        let cutoffEndRadians = max(rimRadians * rimCutoffEndWidths, minimumRadians)
        let skyOpacity = fog.isEnabled ? fogFade : 0

        // The sun the halo brightens toward: the globe's, fixed over its
        // subsolar point and turned with the globe (`GlobeLightUniform
        // .sunWorldDirection`), so the halo's day is the surface's; the
        // flat map's static sun with the globe's light off.
        let globeLight = settings.scene.globeLight
        let lightDirection = globeLight.isEnabled
            ? GlobeLightUniform.sunWorldDirection(settings: globeLight, globe: globe)
            : settings.scene.light.direction
        let light = simd_length_squared(lightDirection) > 1e-12
            ? simd_normalize(lightDirection)
            : SIMD3<Float>(0, 0, 1)

        let reach = max(cutoffEndRadians, featherRadians * 4)
        let cornerAngles = HorizonEdgeMath.cornerDirections(inverseProjectionView: inverseProjectionView,
                                                            eye: cameraEye)
            .map { HorizonEdgeMath.angleAboveEdge(direction: $0, edge: edge) }
        let edgeWithinReach = cornerAngles.contains { $0 >= -reach }
        // The band's top: the plane's sky is opaque to the top of the frame,
        // the globe's halo is done a few glow widths up, and a frame of the
        // handover carries both.
        let frameTop = (cornerAngles.max() ?? 0) + bandTopMarginRadians
        let haloTop = haloRadians(haloGlowRadii) * bandTopGlowWidths
        let bandTopRadians = skyOpacity > 0
            ? max(frameTop, skyGradientRadians * bandTopGlowWidths, haloTop)
            : haloTop
        // Transparent space keeps the sphere unpainted around the planet:
        // no halo there, and the plane's sky arrives with the fade only,
        // the sky draw it brings carrying no halo under it.
        let drawsHalo = renderSurfaceMode == .spherical
            && settings.scene.space.isTransparent == false
            && atmosphereFade > 0
        let haloShare = settings.scene.space.isTransparent ? 0 : atmosphereFade
        let drawsSky = edgeWithinReach && (drawsHalo || skyOpacity > 0)
        let drawsGround = edgeWithinReach && (groundGain > 0 || featherStrength > 0)

        return HorizonHaze(edge: edge,
                           center: curvature > 0 ? SIMD3<Float>(0, 0, -1 / curvature) : SIMD3<Float>(0, 0, -1e6),
                           light: light,
                           sunInfluence: isOn ? min(max(atmosphere.sunInfluence, 0), 1) * haloShare : 0,
                           skyStrength: isOn ? intensity * haloShare : 0,
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
