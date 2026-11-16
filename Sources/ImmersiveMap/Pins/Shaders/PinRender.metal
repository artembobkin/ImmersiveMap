// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Screen/ScreenCommon.h"
#include "PinCommon.h"

struct PinVertexOut {
    float4 position [[position]];
    float2 uvLocal;
    float4 uvRect;
    float4 borderColor;
    float visibilityAlpha;
    float morph;
    uint atlasIndex [[flat]];
    uint flags [[flat]];
};



static inline float decodeSignedDistanceTexels(float encodedDistance,
                                               constant PinStyleGPU& style) {
    return (0.5 - encodedDistance) * (2.0 * style.distanceRangeTexels);
}

vertex PinVertexOut pinVertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    constant float4x4& screenMatrix [[buffer(0)]],
                                    const device ScreenPointOutput* points [[buffer(1)]],
                                    const device PinInstanceGPU* instances [[buffer(2)]],
                                    constant PinStyleGPU& style [[buffer(3)]]) {
    const float2 quad[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };

    PinVertexOut out;
    PinInstanceGPU instance = instances[iid];
    ScreenPointOutput point = points[iid];
    if (point.visible == 0) {
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.uvLocal = float2(0.0);
        out.uvRect = float4(0.0);
        out.borderColor = float4(0.0);
        out.visibilityAlpha = 0.0;
        out.morph = 0.0;
        out.atlasIndex = 0;
        out.flags = 0;
        return out;
    }
    // The quad is laid so that the shape's anchor stands on the pin's point.
    float2 uv = quad[vid];
    float2 local = (uv - style.anchorUv) * style.sizePx * instance.squashScale;
    float2 pixelPosition = point.position + local;

    out.position = screenMatrix * float4(pixelPosition, 0.0, 1.0);
    out.uvLocal = uv;
    out.uvRect = instance.uvRect;
    out.borderColor = instance.borderColor;
    out.visibilityAlpha = point.visibilityAlpha;
    out.morph = instance.morph;
    out.atlasIndex = instance.atlasIndex;
    out.flags = instance.flags;
    return out;
}

// The texel-space SDF math stays float: squared texel distances overflow
// half's range. Sampling and the unit-range mask composition run in half.
// The pipeline blends by the source's alpha, so the color leaves the shader
// not multiplied by it.
fragment half4 pinFragment(PinVertexOut in [[stage_in]],
                              constant PinStyleGPU& style [[buffer(0)]],
                              texture2d_array<half> atlasTexture [[texture(0)]],
                              texture2d<half> sdfTexture [[texture(1)]]) {
    constexpr sampler atlasSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    constexpr sampler sdfSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // A pin without a frame is its picture alone, cut by the picture's alpha.
    if (style.frameless != 0u) {
        float2 pictureUv = mix(in.uvRect.xy, in.uvRect.zw, in.uvLocal);
        half4 picture = atlasTexture.sample(atlasSampler, pictureUv, in.atlasIndex);
        return half4(picture.rgb / max(picture.a, 0.0001h), picture.a * half(in.visibilityAlpha));
    }

    float fillMask;
    float borderMask;
    float interiorMask;
    float imageMask;
    float2 sdfUv = float2(in.uvLocal.x, 1.0 - in.uvLocal.y);
    // A baked shape keeps its distance in red, the built-in bubble in alpha.
    half4 sdfSample = sdfTexture.sample(sdfSampler, sdfUv);
    float encodedDistance = float(style.distanceInAlpha != 0u ? sdfSample.a : sdfSample.r);
    float pinDistanceTexels = decodeSignedDistanceTexels(encodedDistance, style);
    float2 sdfTextureSize = float2(float(sdfTexture.get_width()), float(sdfTexture.get_height()));
    // Pin -> circle morph: an analytic SDF of the body circle in the same
    // texels as the shape's sample, so the masks below stay unchanged.
    float2 circleCenter = style.bodyCenterUv;
    float circleRadiusTexels = style.circleRadiusUv * sdfTextureSize.x;
    float circleDistanceTexels = length((in.uvLocal - circleCenter) * sdfTextureSize) - circleRadiusTexels;
    float shapeDistanceTexels = mix(pinDistanceTexels, circleDistanceTexels, saturate(in.morph));
    float texelsPerPixelX = length(dfdx(in.uvLocal) * sdfTextureSize);
    float texelsPerPixelY = length(dfdy(in.uvLocal) * sdfTextureSize);
    float texelsPerPixel = max(max(texelsPerPixelX, texelsPerPixelY), 0.0001);
    float edgeWidthTexels = max(0.75 * texelsPerPixel, 0.75);
    float outlineWidthTexels = max(style.outlineWidthPx * texelsPerPixel, edgeWidthTexels);
    fillMask = 1.0 - smoothstep(-edgeWidthTexels, edgeWidthTexels, shapeDistanceTexels);
    // An outline of no width is no outline, not a hairline.
    borderMask = style.outlineWidthPx > 0.0
        ? smoothstep(-outlineWidthTexels - edgeWidthTexels, -edgeWidthTexels, shapeDistanceTexels) * fillMask
        : 0.0;
    interiorMask = max(fillMask - borderMask, 0.0);
    float contentInsetTexels = max(style.contentInsetPx * texelsPerPixel,
                                   style.outlineWidthPx > 0.0 ? outlineWidthTexels + edgeWidthTexels : 0.0);
    imageMask = 1.0 - smoothstep(-contentInsetTexels - edgeWidthTexels,
                                 -contentInsetTexels + edgeWidthTexels,
                                 shapeDistanceTexels);
    imageMask *= interiorMask;

    // The picture is laid into the picture area, set in by the inset, and is
    // centered on the circle a pushed pin turns into.
    float2 insetUv = float2(style.contentInsetPx) / max(style.sizePx, float2(1.0));
    float2 contentHalfUv = max(style.bodyHalfUv - insetUv, float2(0.0001));
    float2 imageUv = clamp((in.uvLocal - (circleCenter - contentHalfUv)) / (2.0 * contentHalfUv), 0.0, 1.0);
    float2 atlasUv = mix(in.uvRect.xy, in.uvRect.zw, imageUv);
    half4 tex = atlasTexture.sample(atlasSampler, atlasUv, in.atlasIndex);

    // Everything below is multiplied by its own alpha until the last line.
    half4 fill = half4(half3(style.fillColor.rgb) * half(style.fillColor.a), half(style.fillColor.a));
    half4 outline = half4(half3(in.borderColor.rgb) * half(in.borderColor.a), half(in.borderColor.a));
    // A picture with transparent parts lies on the fill, not on the map.
    half4 pictureOnFill = tex + fill * (1.0h - tex.a);
    half hImageMask = half(imageMask);
    half hBorderMask = half(borderMask);
    half fillBandMask = half(max(interiorMask - imageMask, 0.0));
    half4 color = pictureOnFill * hImageMask + fill * fillBandMask + outline * hBorderMask;
    return half4(color.rgb / max(color.a, 0.0001h), color.a * half(in.visibilityAlpha));
}





struct PinCountBadgeVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 uvRect;
    float visibilityAlpha;
    float contentAlpha;
};

vertex PinCountBadgeVertexOut pinCountBadgeVertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant float4x4& screenMatrix [[buffer(0)]],
    const device ScreenPointOutput* points [[buffer(1)]],
    const device PinCountBadgeInstanceGPU* instances [[buffer(2)]],
    constant PinCountBadgeStyleGPU& style [[buffer(3)]]
) {
    const float2 quad[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
    };

    PinCountBadgeVertexOut out;
    PinCountBadgeInstanceGPU instance = instances[iid];
    ScreenPointOutput point = points[iid];
    if (point.visible == 0 || (instance.flags & 1u) == 0u || instance.contentAlpha <= 0.0) {
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.uv = float2(0.0);
        out.uvRect = float4(0.0);
        out.visibilityAlpha = 0.0;
        out.contentAlpha = 0.0;
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
    out.contentAlpha = instance.contentAlpha;
    return out;
}

fragment half4 pinCountBadgeFragment(PinCountBadgeVertexOut in [[stage_in]],
                                        texture2d<half> badgeAtlas [[texture(0)]]) {
    constexpr sampler badgeSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = mix(in.uvRect.xy, in.uvRect.zw, in.uv);
    half4 color = badgeAtlas.sample(badgeSampler, uv);
    color.a *= half(in.visibilityAlpha * in.contentAlpha);
    return color;
}
