// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

#ifndef SCREEN_COMMON
#define SCREEN_COMMON

struct ScreenPointOutput {
    float2 position; // NDC or pixel position, depending on outputPixels
    float depth;     // Clip-space depth (z / w)
    uint visible;    // 0 = clipped/behind, 1 = visible
    float visibilityAlpha; // Soft visibility factor; 1 for fully visible, 0 for hidden
};

#endif
