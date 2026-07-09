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
    out.uv = in.uv;
    bool isVisible = (screenPoint.visible != 0u) &&
                     (runtimeState.duplicate == 0u);
    out.alpha = isVisible ? runtimeState.fadeAlpha : 0.0;
    out.spriteUV = in.spriteUV;
    return out;
}

fragment float4 poiSpriteFragment(VertexOut in [[stage_in]],
                                  texture2d<float> atlasTexture [[texture(0)]],
                                  constant PoiIconStyle& style [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 texel = atlasTexture.sample(textureSampler, in.uv);
    float2 centeredUV = in.spriteUV * 2.0 - 1.0;
    float circleDistance = length(centeredUV);
    float circleAlpha = 1.0 - smoothstep(0.82, 0.96, circleDistance);
    float iconAlpha = texel.a;

    float backgroundAlpha = circleAlpha * in.alpha * style.backgroundColor.a;
    float foregroundAlpha = iconAlpha * in.alpha * style.iconColor.a;
    float alpha = foregroundAlpha + backgroundAlpha * (1.0 - foregroundAlpha);
    float3 color = style.iconColor.rgb * foregroundAlpha
        + style.backgroundColor.rgb * backgroundAlpha * (1.0 - foregroundAlpha);
    return float4(color, alpha);
}
