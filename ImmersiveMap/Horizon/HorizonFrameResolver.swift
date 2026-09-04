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
/// - **The fog band**, always on the flat map: the ground blends into the
///   map's clear colour by angle below the horizon, saturating at the line
///   and gone a few degrees under it, so the far range meets the sky with no
///   seam and the map under the camera stays byte-clean.
///
/// The morph hands the first two over to the last on the semantic
/// transition: unchanged until `handoverStart`, then the halo fades out, the
/// rim narrows into the fog band's widths and every colour blends to the fog
/// colour, all finished by `handoverEnd`, where the geometry is a finished
/// plane. The surface switch at 1 then happens between identical frames.
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
    /// Whether the sky-side draw (pixels nothing painted) runs this frame.
    var drawsSky: Bool
    /// Whether the ground-side draw (painted pixels) runs this frame.
    var drawsGround: Bool
}

enum HorizonFrameResolver {
    /// The handover window on the semantic transition.
    static let handoverStart: Float = 0.5
    static let handoverEnd: Float = 0.9

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

    /// The fog band, radians below the flat horizon: one exponential with a
    /// gain above one so it saturates to the fog colour at the line, cut off
    /// smoothly a few degrees under it.
    static let fogBandRadians: Float = 1.2 * .pi / 180
    static let fogGain: Float = 1.6
    static let fogCutoffStartRadians: Float = 4 * .pi / 180
    static let fogCutoffEndRadians: Float = 6 * .pi / 180

    /// The limb feather: its e-fold width in pixels and its peak coverage.
    static let featherPixels: Float = 1.5
    static let featherPeakStrength: Float = 0.85

    /// Widths are e-fold denominators in the shader; a zero would divide.
    static let minimumRadians: Float = 1e-4

    static func handover(transition: Float, renderSurfaceMode: ViewMode) -> Float {
        guard renderSurfaceMode == .spherical else { return 1 }
        let t = simd_clamp((transition - handoverStart) / (handoverEnd - handoverStart), 0, 1)
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
        let radius = max(globe.radius, 1e-6)
        let curvature = renderSurfaceMode == .spherical
            ? max(1 - min(max(globe.transition, 0), 1), 0) / radius
            : 0
        let edge = HorizonEdgeMath.edge(eye: cameraEye, curvature: curvature)
        let s = handover(transition: transition, renderSurfaceMode: renderSurfaceMode)
        let thickness = max(atmosphere.thickness, 0.05)
        let intensity = max(atmosphere.intensity, 0)

        // A shell of `radii` planet radii subtends `radii * R / limbDistance`
        // at the limb; infinite limb distance (the plane) gives zero.
        func haloRadians(_ radii: Float) -> Float {
            max(min(radii * radius * thickness / edge.limbDistance, maximumHaloRadians), minimumRadians)
        }
        // Exact at both ends: at s = 1 the plane's value is reproduced bit for
        // bit, which is what makes the surface switch happen between
        // identical frames.
        func mix(_ a: Float, _ b: Float) -> Float { a * (1 - s) + b * s }

        let fogColor = SIMD3<Float>(Float(settings.scene.mapClearColor.x),
                                    Float(settings.scene.mapClearColor.y),
                                    Float(settings.scene.mapClearColor.z))
        let restingTint = isOn ? atmosphere.color : fogColor
        let tint = restingTint * (1 - s) + fogColor * s

        let rimRadians = haloRadians(haloRimRadii)
        let featherRadians = max(featherPixels * verticalFovRadians / max(drawableHeightPx, 1), minimumRadians)
        let featherStrength = featherPeakStrength * (1 - s)
        let groundGain = mix(isOn ? intensity : 0, fogGain)
        let cutoffEndRadians = max(mix(rimRadians * rimCutoffEndWidths, fogCutoffEndRadians), minimumRadians)

        let lightDirection = settings.scene.light.direction
        let light = simd_length_squared(lightDirection) > 1e-12
            ? simd_normalize(lightDirection)
            : SIMD3<Float>(0, 0, 1)

        let inverseProjectionView = simd_inverse(projectionView)
        let reach = max(cutoffEndRadians, featherRadians * 4)
        let edgeWithinReach = HorizonEdgeMath.isEdgeWithinReach(edge: edge,
                                                                reachBelow: reach,
                                                                inverseProjectionView: inverseProjectionView,
                                                                eye: cameraEye)
        let drawsSky = renderSurfaceMode == .spherical
            && settings.scene.space.isTransparent == false
            && s < 1
            && edgeWithinReach
        let drawsGround = edgeWithinReach && (groundGain > 0 || featherStrength > 0)

        return HorizonHaze(edge: edge,
                           center: curvature > 0 ? SIMD3<Float>(0, 0, -1 / curvature) : SIMD3<Float>(0, 0, -1e6),
                           light: light,
                           sunInfluence: isOn ? min(max(atmosphere.sunInfluence, 0), 1) * (1 - s) : 0,
                           skyStrength: isOn ? intensity * (1 - s) : 0,
                           tint: tint,
                           whitenWeight: isOn ? haloWhitenWeight * (1 - s) : 0,
                           featherStrength: featherStrength,
                           bandRadians: haloRadians(haloBandRadii),
                           glowRadians: haloRadians(haloGlowRadii),
                           whitenRadians: haloRadians(haloWhitenRadii),
                           featherRadians: featherRadians,
                           groundBandRadians: max(mix(rimRadians, fogBandRadians), minimumRadians),
                           groundGain: groundGain,
                           cutoffStartRadians: max(mix(rimRadians * rimCutoffStartWidths, fogCutoffStartRadians), minimumRadians),
                           cutoffEndRadians: cutoffEndRadians,
                           drawsSky: drawsSky,
                           drawsGround: drawsGround)
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
