// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

/// The Hermite step of the shaders, on the CPU: 0 at `edge0` and before
/// it, 1 at `edge1` and past it, eased between.
func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
    let t = simd_clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
}
