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
    float2 pinCenterOffsetPx;
    float pinBodyHalfMinPx;
    float _padding;
};

// Mirrors PinStyleGPU in PinTypes.swift. The fractions are of the pin's quad,
// origin in the bottom left corner, y up.
struct PinStyleGPU {
    float2 sizePx;
    float2 anchorUv;
    float2 bodyCenterUv;
    float2 bodyHalfUv;
    float circleRadiusUv;
    float outlineWidthPx;
    float contentInsetPx;
    float distanceRangeTexels;
    float4 fillColor;
    uint frameless;
    uint distanceInAlpha;
    float2 _pad1;
};



struct PinCountBadgeStyleGPU {
    float2 sizePx;
    float originXPx;
    float originYPx;
};

#endif
