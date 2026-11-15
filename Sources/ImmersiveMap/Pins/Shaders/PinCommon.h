// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

#ifndef PIN_COMMON
#define PIN_COMMON

struct PinInstanceGPU {
    float4 uvRect;
    float4 borderColor;
    float2 squashScale;
    uint atlasIndex;
    uint flags;
    float morph;
    float _pad0;
    float2 _pad1;
};



struct PinCountBadgeInstanceGPU {
    float4 uvRect;
    uint flags;
    float screenSizeScale;
    float contentAlpha;
    float _padding;
};

struct PinOffset {
    float2 value;
    float scale;
    float _padding;
};

struct PinBeamStyleGPU {
    float pinCenterOffsetPx;
    float pinBodyHalfMinPx;
    float2 _padding;
};

struct PinStyleGPU {
    float2 bodySizePx;
    float2 totalSizePx;
    float cornerRadiusPx;
    float pointerHeightPx;
    float pointerHalfWidthPx;
    float outlineWidthPx;
    float contentInsetPx;
};



struct PinCountBadgeStyleGPU {
    float2 sizePx;
    float originXPx;
    float originYPx;
};

struct PinSDFParams {
    float distanceRangeTexels;
};

#endif
