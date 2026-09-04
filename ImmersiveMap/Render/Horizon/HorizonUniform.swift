// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame parameters of the horizon layer; the layout mirrors `Horizon`
/// in Horizon.metal (pinned by `HorizonUniformLayoutTests`). The values are
/// resolved by `HorizonFrameResolver`; this is only their GPU shape.
struct HorizonUniform {
    /// Inverse of the frame's view-projection: turns a far-plane clip point
    /// back into world space, which with the eye gives the view ray.
    var inverseViewProjection: matrix_float4x4
    /// The eye's local vertical.
    var up: SIMD3<Float>
    /// The edge's depression below the local horizontal, radians.
    var depression: Float
    var center: SIMD3<Float>
    var sunInfluence: Float
    var light: SIMD3<Float>
    var skyStrength: Float
    var tint: SIMD3<Float>
    var whitenWeight: Float
    var eye: SIMD3<Float>
    var featherStrength: Float
    var bandRadians: Float
    var glowRadians: Float
    var whitenRadians: Float
    var featherRadians: Float
    var groundBandRadians: Float
    var groundGain: Float
    var cutoffStartRadians: Float
    var cutoffEndRadians: Float

    static func make(haze: HorizonHaze,
                     projectionView: matrix_float4x4,
                     cameraEye: SIMD3<Float>) -> HorizonUniform {
        HorizonUniform(inverseViewProjection: simd_inverse(projectionView),
                       up: haze.edge.up,
                       depression: haze.edge.depression,
                       center: haze.center,
                       sunInfluence: haze.sunInfluence,
                       light: haze.light,
                       skyStrength: haze.skyStrength,
                       tint: haze.tint,
                       whitenWeight: haze.whitenWeight,
                       eye: cameraEye,
                       featherStrength: haze.featherStrength,
                       bandRadians: haze.bandRadians,
                       glowRadians: haze.glowRadians,
                       whitenRadians: haze.whitenRadians,
                       featherRadians: haze.featherRadians,
                       groundBandRadians: haze.groundBandRadians,
                       groundGain: haze.groundGain,
                       cutoffStartRadians: haze.cutoffStartRadians,
                       cutoffEndRadians: haze.cutoffEndRadians)
    }
}
