// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Light matrix of the caster pass; the layout mirrors
/// `ShadowCasterMatrices` in RenderUniforms.h (pinned by
/// `ShadowUniformLayoutTests`). One shadow window means one matrix, so a
/// caster geometry renders with one draw and no instancing.
struct ShadowCasterUniform {
    var lightProjectionView: matrix_float4x4
}
