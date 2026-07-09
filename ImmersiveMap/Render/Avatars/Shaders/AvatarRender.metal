// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Screen/ScreenCommon.h"
#include "AvatarCommon.h"

struct AvatarVertexOut {
    float4 position [[position]];
    float2 uvLocal;
    float4 uvRect;
    float4 borderColor;
    float visibilityAlpha;
    uint atlasIndex [[flat]];
    uint flags [[flat]];
};

struct AvatarBatteryBadgeVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 uvRect;
    float visibilityAlpha;
};

struct AvatarSpeedBadgeVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 uvRect;
    float visibilityAlpha;
};

static inline float decodeSignedDistanceTexels(float encodedDistance,
                                               constant AvatarMarkerSDFParams& sdfParams) {
    return (0.5 - encodedDistance) * (2.0 * sdfParams.distanceRangeTexels);
}

vertex AvatarVertexOut avatarVertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    constant float4x4& screenMatrix [[buffer(0)]],
                                    const device ScreenPointOutput* points [[buffer(1)]],
                                    const device AvatarInstanceGPU* instances [[buffer(2)]],
                                    constant AvatarMarkerStyleGPU& style [[buffer(3)]]) {
    const float2 quad[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };

    AvatarVertexOut out;
    AvatarInstanceGPU instance = instances[iid];
    ScreenPointOutput point = points[iid];
    if (point.visible == 0) {
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.uvLocal = float2(0.0);
        out.uvRect = float4(0.0);
        out.borderColor = float4(0.0);
        out.visibilityAlpha = 0.0;
        out.atlasIndex = 0;
        out.flags = 0;
        return out;
    }
    float2 uv = quad[vid];
    float2 local = float2((uv.x - 0.5) * style.totalSizePx.x,
                          uv.y * style.totalSizePx.y) * instance.squashScale;
    float2 pixelPosition = point.position + local;

    out.position = screenMatrix * float4(pixelPosition, 0.0, 1.0);
    out.uvLocal = uv;
    out.uvRect = instance.uvRect;
    out.borderColor = instance.borderColor;
    out.visibilityAlpha = point.visibilityAlpha;
    out.atlasIndex = instance.atlasIndex;
    out.flags = instance.flags;
    return out;
}

fragment float4 avatarFragment(AvatarVertexOut in [[stage_in]],
                               constant AvatarMarkerStyleGPU& style [[buffer(0)]],
                               constant AvatarMarkerSDFParams& sdfParams [[buffer(1)]],
                               texture2d_array<float> atlasTexture [[texture(0)]],
                               texture2d<float> sdfTexture [[texture(1)]]) {
    constexpr sampler atlasSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    constexpr sampler sdfSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float fillMask;
    float borderMask;
    float interiorMask;
    float imageMask;
    float2 sdfUv = float2(in.uvLocal.x, 1.0 - in.uvLocal.y);
    float4 mtsdfSample = sdfTexture.sample(sdfSampler, sdfUv);
    float encodedDistance = mtsdfSample.a;
    float markerDistanceTexels = decodeSignedDistanceTexels(encodedDistance, sdfParams);
    float2 sdfTextureSize = float2(float(sdfTexture.get_width()), float(sdfTexture.get_height()));
    float texelsPerPixelX = length(dfdx(in.uvLocal) * sdfTextureSize);
    float texelsPerPixelY = length(dfdy(in.uvLocal) * sdfTextureSize);
    float texelsPerPixel = max(max(texelsPerPixelX, texelsPerPixelY), 0.0001);
    float edgeWidthTexels = max(0.75 * texelsPerPixel, 0.75);
    float outlineWidthTexels = max(style.outlineWidthPx * texelsPerPixel, edgeWidthTexels);
    fillMask = 1.0 - smoothstep(-edgeWidthTexels, edgeWidthTexels, markerDistanceTexels);
    borderMask = smoothstep(-outlineWidthTexels - edgeWidthTexels, -edgeWidthTexels, markerDistanceTexels) * fillMask;
    interiorMask = max(fillMask - borderMask, 0.0);
    float contentInsetTexels = max(style.contentInsetPx * texelsPerPixel, outlineWidthTexels + edgeWidthTexels);
    imageMask = 1.0 - smoothstep(-contentInsetTexels - edgeWidthTexels,
                                 -contentInsetTexels + edgeWidthTexels,
                                 markerDistanceTexels);
    imageMask *= interiorMask;

    float2 insetUv = float2(style.contentInsetPx / max(style.totalSizePx.x, 1.0),
                            style.contentInsetPx / max(style.totalSizePx.y, 1.0));
    float2 imageUv = clamp((in.uvLocal - insetUv) / max(float2(1.0) - 2.0 * insetUv, float2(0.0001)), 0.0, 1.0);
    float2 atlasUv = mix(in.uvRect.xy, in.uvRect.zw, imageUv);
    float4 tex = atlasTexture.sample(atlasSampler, atlasUv, in.atlasIndex);

    float whiteFillMask = max(interiorMask - imageMask, 0.0);
    float4 imageColor = tex * imageMask;
    float4 whiteFillColor = float4(1.0, 1.0, 1.0, 1.0) * whiteFillMask;
    float4 outlineColor = float4(0.0, 0.0, 0.0, 1.0) * borderMask;
    float4 color = imageColor + whiteFillColor + outlineColor;
    float alpha = tex.a * imageMask + whiteFillMask + borderMask;
    color.a = alpha * in.visibilityAlpha;
    return color;
}

vertex AvatarBatteryBadgeVertexOut avatarBatteryBadgeVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant float4x4& screenMatrix [[buffer(0)]],
    const device ScreenPointOutput* points [[buffer(1)]],
    const device AvatarBatteryBadgeInstanceGPU* instances [[buffer(2)]],
    constant AvatarBatteryBadgeStyleGPU& style [[buffer(3)]]
) {
    const float2 quad[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };

    AvatarBatteryBadgeVertexOut out;
    AvatarBatteryBadgeInstanceGPU instance = instances[iid];
    ScreenPointOutput point = points[iid];
    if (point.visible == 0 || (instance.flags & 1u) == 0u) {
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.uv = float2(0.0);
        out.uvRect = float4(0.0);
        out.visibilityAlpha = 0.0;
        return out;
    }

    float2 uv = quad[vid];
    float screenSizeScale = max(instance.screenSizeScale, 0.0);
    float badgeBottom = -(style.gapPx + style.sizePx.y) * screenSizeScale;
    float2 local = float2((uv.x - 0.5) * style.sizePx.x * screenSizeScale,
                          badgeBottom + uv.y * style.sizePx.y * screenSizeScale);
    float2 pixelPosition = point.position + local;

    out.position = screenMatrix * float4(pixelPosition, 0.0, 1.0);
    out.uv = uv;
    out.uvRect = instance.uvRect;
    out.visibilityAlpha = point.visibilityAlpha;
    return out;
}

fragment float4 avatarBatteryBadgeFragment(AvatarBatteryBadgeVertexOut in [[stage_in]],
                                           texture2d<float> badgeAtlas [[texture(0)]]) {
    constexpr sampler badgeSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = mix(in.uvRect.xy, in.uvRect.zw, in.uv);
    float4 color = badgeAtlas.sample(badgeSampler, uv);
    color.a *= in.visibilityAlpha;
    return color;
}

vertex AvatarSpeedBadgeVertexOut avatarSpeedBadgeVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant float4x4& screenMatrix [[buffer(0)]],
    const device ScreenPointOutput* points [[buffer(1)]],
    const device AvatarSpeedBadgeInstanceGPU* instances [[buffer(2)]],
    constant AvatarSpeedBadgeStyleGPU& style [[buffer(3)]]
) {
    const float2 quad[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };

    AvatarSpeedBadgeVertexOut out;
    AvatarSpeedBadgeInstanceGPU instance = instances[iid];
    ScreenPointOutput point = points[iid];
    if (point.visible == 0 || (instance.flags & 1u) == 0u) {
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.uv = float2(0.0);
        out.uvRect = float4(0.0);
        out.visibilityAlpha = 0.0;
        return out;
    }

    float2 uv = quad[vid];
    float screenSizeScale = max(instance.screenSizeScale, 0.0);
    float2 local = float2(style.originXPx * screenSizeScale + uv.x * style.sizePx.x * screenSizeScale,
                          style.originYPx * screenSizeScale + uv.y * style.sizePx.y * screenSizeScale);
    float2 pixelPosition = point.position + local;

    out.position = screenMatrix * float4(pixelPosition, 0.0, 1.0);
    out.uv = uv;
    out.uvRect = instance.uvRect;
    out.visibilityAlpha = point.visibilityAlpha;
    return out;
}

fragment float4 avatarSpeedBadgeFragment(AvatarSpeedBadgeVertexOut in [[stage_in]],
                                         texture2d<float> badgeAtlas [[texture(0)]]) {
    constexpr sampler badgeSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = mix(in.uvRect.xy, in.uvRect.zw, in.uv);
    float4 color = badgeAtlas.sample(badgeSampler, uv);
    color.a *= in.visibilityAlpha;
    return color;
}
