// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Frozen per-frame shadow state resolved in `collectInput`: the light
/// cameras for the caster passes, one per window of the map
/// (`ShadowCascadeSlot`), and the sampling uniform for every receiver. `nil`
/// on `FrameContext` means "no shadows this frame" (globe mode, disabled, or
/// a degenerate light).
struct ShadowFrameState {
    /// World → clip matrix of the directional light's orthographic camera
    /// for the near window.
    let lightProjectionView: matrix_float4x4
    /// The same for the far window, nil when the frame has none: the far
    /// coverage does not reach past the near window.
    let farLightProjectionView: matrix_float4x4?
    let shadowUniform: ShadowUniform
    /// Square side of every slice of the shadow map in pixels.
    let mapResolution: Int

    init(lightProjectionView: matrix_float4x4,
         farLightProjectionView: matrix_float4x4? = nil,
         shadowUniform: ShadowUniform,
         mapResolution: Int) {
        self.lightProjectionView = lightProjectionView
        self.farLightProjectionView = farLightProjectionView
        self.shadowUniform = shadowUniform
        self.mapResolution = mapResolution
    }

    /// The windows this frame renders, the near one always.
    var slots: [ShadowCascadeSlot] {
        farLightProjectionView == nil ? [.near] : [.near, .far]
    }

    /// The light camera a window's casters draw with, nil for a window the
    /// frame has not got.
    func lightProjectionView(for slot: ShadowCascadeSlot) -> matrix_float4x4? {
        switch slot {
        case .near: lightProjectionView
        case .far: farLightProjectionView
        }
    }

    /// The light camera to cull casters by: the far window's, which holds
    /// the near one, so a caster outside it casts into neither.
    var casterCullingProjectionView: matrix_float4x4 {
        farLightProjectionView ?? lightProjectionView
    }
}
