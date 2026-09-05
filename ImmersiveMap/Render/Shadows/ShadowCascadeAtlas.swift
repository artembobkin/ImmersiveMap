// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Format of the shadow map: one square depth texture, written by the caster
/// pass and compared against by every receiver. Shared by the caster
/// pipelines, the attachment store and the resolver's UV math so they can
/// never disagree.
///
/// There is one window rather than a cascade set: it is fitted to a disc whose
/// radius is a multiple of the camera distance, so its texel world size (and
/// therefore edge sharpness) is the same at every zoom, and shadows simply end
/// at `ShadowSettings.coverageCameraDistances` where the eye-distance fade
/// takes over. That also keeps the pass free of layered rendering, which the
/// iOS Simulator does not implement.
enum ShadowCascadeAtlas {
    /// 16 bits are enough: the projection is refit to a tight caster range
    /// with depth clamping, so the extra depth32Float precision bought nothing
    /// while doubling the map's memory and the bandwidth of every
    /// `sample_compare`.
    static let depthPixelFormat: MTLPixelFormat = .depth16Unorm
}
