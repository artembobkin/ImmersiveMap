// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Light matrices of the caster pass, one per cascade; the layout mirrors
/// `ShadowCasterMatrices` in RenderUniforms.h (pinned by
/// `ShadowUniformLayoutTests`). The caster vertex stages index the array by
/// `[[instance_id]]` and route each instance to the matching slice of the
/// shadow texture array, so all cascades render in one pass with one draw per
/// geometry.
struct ShadowCasterUniform {
    var near: matrix_float4x4
    var middle: matrix_float4x4
    var far: matrix_float4x4

    /// `lightProjectionViews` is `[near, middle, far]`, the order
    /// `ShadowFrameStateResolver` produces and `Shadow.cascades` samples.
    init(lightProjectionViews: [matrix_float4x4]) {
        precondition(lightProjectionViews.count == ShadowCascadeAtlas.cascadeCount,
                     "Expected one light matrix per cascade")
        near = lightProjectionViews[0]
        middle = lightProjectionViews[1]
        far = lightProjectionViews[2]
    }
}
