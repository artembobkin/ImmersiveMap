// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  PoiSprite.metal
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/LabelRuntimeMeta.h"
#include "../Shared/LabelTextCommon.h"

struct PoiIconStyle {
    float4 backgroundColor;
    float4 iconColor;
};

vertex VertexOut poiSpriteVertex(LabelVertexIn in [[stage_in]],
                                 constant float4x4& matrix [[buffer(1)]],
                                 const device ScreenPointOutput* screenPositions [[buffer(2)]],
                                 constant int& globalTextShift [[buffer(3)]],
                                 const device LabelRuntimeMeta* labelMeta [[buffer(6)]]) {
    VertexOut out;
    int screenIndex = in.labelIndex + globalTextShift;
    ScreenPointOutput screenPoint = screenPositions[screenIndex];
    LabelRuntimeMeta runtimeState = labelMeta[screenIndex];

    float2 halfSize = runtimeState.labelSizePx * 0.5;
    float2 pixelPosition = screenPoint.position + in.position - halfSize;
    out.position = matrix * float4(pixelPosition, 0.0, 1.0);
    // Far-plane depth: the cleared overlay depth (1.0) passes the labels'
    // lessEqual test, while the scene model occlusion prepass depth, always
    // closer, clips the label to the model silhouette.
    out.position.z = out.position.w;
    out.uv = in.uv;
    bool isVisible = (screenPoint.visible != 0u) &&
                     (runtimeState.duplicate == 0u);
    out.alpha = isVisible ? runtimeState.fadeAlpha : 0.0;
    out.spriteUV = in.spriteUV;
    return out;
}

// Everything after the sample is unit-range, so the composite runs in half.
fragment half4 poiSpriteFragment(VertexOut in [[stage_in]],
                                 texture2d<half> atlasTexture [[texture(0)]],
                                 constant PoiIconStyle& style [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    half4 texel = atlasTexture.sample(textureSampler, in.uv);
    half2 centeredUV = half2(in.spriteUV) * 2.0h - 1.0h;
    half circleDistance = length(centeredUV);
    half circleAlpha = 1.0h - smoothstep(0.82h, 0.96h, circleDistance);
    half iconAlpha = texel.a;

    half vertexAlpha = half(in.alpha);
    half backgroundAlpha = circleAlpha * vertexAlpha * half(style.backgroundColor.a);
    half foregroundAlpha = iconAlpha * vertexAlpha * half(style.iconColor.a);
    half alpha = foregroundAlpha + backgroundAlpha * (1.0h - foregroundAlpha);
    half3 color = half3(style.iconColor.rgb) * foregroundAlpha
        + half3(style.backgroundColor.rgb) * backgroundAlpha * (1.0h - foregroundAlpha);
    return half4(color, alpha);
}
