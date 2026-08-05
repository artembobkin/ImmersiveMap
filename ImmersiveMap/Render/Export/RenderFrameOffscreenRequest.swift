// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Metal

/// One offscreen frame request for `RenderFrameEngine.render(offscreen:)`,
/// used by the offline video export path.
struct RenderFrameOffscreenRequest {
    /// Color texture to render into: `.bgra8Unorm`, usage
    /// `[.renderTarget, .shaderRead]`, dimensions matching `drawSize`.
    let texture: MTLTexture
    /// Render size in pixels.
    let drawSize: CGSize
    /// Drawable pixels per layout point for style values expressed in points.
    let pixelsPerPoint: CGFloat
    /// Invoked on the Metal completion thread after the frame's GPU work
    /// finished (`true` on success). Fires only when the render call returned
    /// `true`: a skipped frame never schedules GPU work.
    let onGPUComplete: @Sendable (Bool) -> Void
}
