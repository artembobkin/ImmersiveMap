// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

/// The color destination of one rendered frame.
///
/// The live path wraps a `CAMetalDrawable` (its texture plus the drawable to
/// present); the offscreen path wraps a caller-supplied texture and presents
/// nothing. Pass descriptor providers only ever read `texture`.
struct FrameRenderTarget {
    /// Color texture the drawable-bound passes render into.
    let texture: MTLTexture
    /// Non-nil only on the live `CAMetalLayer` path; presented after commit.
    let drawable: CAMetalDrawable?

    init(texture: MTLTexture, drawable: CAMetalDrawable? = nil) {
        self.texture = texture
        self.drawable = drawable
    }

    init(drawable: CAMetalDrawable) {
        self.texture = drawable.texture
        self.drawable = drawable
    }
}
