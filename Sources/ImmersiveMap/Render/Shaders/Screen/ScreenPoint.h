// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "ScreenCommon.h"

#ifndef SCREEN_POINT
#define SCREEN_POINT

static inline ScreenPointOutput screenPointFromClip(float4 clip,
                                                    constant ScreenParams& screenParams) {
    ScreenPointOutput result;
    if (clip.w <= 0.0) {
        result.position = float2(0.0);
        result.depth = 0.0;
        result.visible = 0;
        result.visibilityAlpha = 0.0;
        return result;
    }

    float2 ndc = clip.xy / clip.w;
    float depth = clip.z / clip.w;
    float2 position = ndc;

    if (screenParams.outputPixels != 0 && all(screenParams.viewportSize > 0.0)) {
        position = (ndc * 0.5 + 0.5) * screenParams.viewportSize;
    }

    result.position = position;
    result.depth = depth;
    result.visible = 1;
    result.visibilityAlpha = 1.0;
    return result;
}

#endif
