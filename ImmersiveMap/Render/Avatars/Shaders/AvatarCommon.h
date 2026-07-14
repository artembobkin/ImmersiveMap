// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

#ifndef AVATAR_COMMON
#define AVATAR_COMMON

struct AvatarInstanceGPU {
    float4 uvRect;
    float4 borderColor;
    float2 squashScale;
    uint atlasIndex;
    uint flags;
    float morph;
    float _pad0;
    float2 _pad1;
};

struct AvatarBatteryBadgeInstanceGPU {
    float4 uvRect;
    uint flags;
    float screenSizeScale;
    float contentAlpha;
    float _padding;
};

struct AvatarSpeedBadgeInstanceGPU {
    float4 uvRect;
    uint flags;
    float screenSizeScale;
    float contentAlpha;
    float _padding;
};

struct AvatarOffset {
    float2 value;
    float scale;
    float _padding;
};

struct AvatarBeamStyleGPU {
    float markerCenterOffsetPx;
    float markerBodyHalfMinPx;
    float2 _padding;
};

struct AvatarMarkerStyleGPU {
    float2 bodySizePx;
    float2 totalSizePx;
    float cornerRadiusPx;
    float pointerHeightPx;
    float pointerHalfWidthPx;
    float outlineWidthPx;
    float contentInsetPx;
};

struct AvatarBatteryBadgeStyleGPU {
    float2 sizePx;
    float gapPx;
    float cornerRadiusPx;
};

struct AvatarSpeedBadgeStyleGPU {
    float2 sizePx;
    float originXPx;
    float originYPx;
};

struct AvatarMarkerSDFParams {
    float distanceRangeTexels;
};

#endif
