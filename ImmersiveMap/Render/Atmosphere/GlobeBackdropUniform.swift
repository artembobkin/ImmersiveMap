// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame input of the globe backdrop (the luminous planet body drawn
/// before the tiles); the layout mirrors `GlobeBackdrop` in Atmosphere.metal
/// (pinned by `AtmosphereUniformLayoutTests`). The matrices are the same
/// composed sphere transforms the tile and cap vertex stages ride
/// (GlobeFrameConstantsUniform), so the body can never detach from the
/// surface drawn over it.
struct GlobeBackdropUniform {
    var sphereClip: matrix_float4x4
    var sphereWorld: matrix_float4x4
    var eye: SIMD3<Float>
    /// 1 on the resting sphere; fades to 0 over the unfurl's early window
    /// (the same window as the atmosphere halo). 0 skips the draw.
    var fade: Float

    /// The unfurl window over which the body fades out, matching the halo's
    /// `kAtmosphereTransitionFadeEnd`.
    static let transitionFadeEnd: Float = 0.35

    static func make(globe: GlobeUniform,
                     cameraMatrix: matrix_float4x4,
                     cameraEye: SIMD3<Float>) -> GlobeBackdropUniform {
        let frame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: cameraMatrix)
        let t = min(max(globe.transition / transitionFadeEnd, 0), 1)
        let fade = 1 - t * t * (3 - 2 * t)
        return GlobeBackdropUniform(sphereClip: frame.sphereClip,
                                    sphereWorld: frame.sphereWorld,
                                    eye: cameraEye,
                                    fade: fade)
    }
}
