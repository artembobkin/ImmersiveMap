// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Labels/Shaders/Shared/LabelTextCommon.h"

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct TextStyle {
    float3 textColor;
    float _padding0;
    float3 strokeColor;
    float strokeWidthPx;
};

struct TextDistance {
    float msdfPxDist;
    float sdfPxDist;
    float screenPxRange;
};

vertex VertexOut textVertex(VertexIn in [[stage_in]],
                            constant float4x4& matrix [[buffer(1)]]
                            ) {
    VertexOut out;
    out.position = matrix * in.position;
    out.uv = in.uv;
    out.alpha = 1.0;
    out.spriteUV = float2(0.0);
    return out;
}

// Px-space distances stay float: screenPxRange comes from uv derivatives that
// shrink below half's normal range on magnified glyphs. The unit-range tail
// (fill/stroke coverage, color mixing) runs in half; the 8-bit target cannot
// see the difference and A-series GPUs execute half at twice the float rate.
static TextDistance computeTextDistance(VertexOut in,
                                        texture2d<half> atlasTexture) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    half4 atlasSample = atlasTexture.sample(textureSampler, in.uv);
    half3 msdf = atlasSample.rgb;
    float sd = float(max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b))) - 0.5;
    float sdf = float(atlasSample.a) - 0.5;
    const float distanceRange = 24.0;
    float2 texSize = float2(atlasTexture.get_width(), atlasTexture.get_height());
    float2 unitRange = float2(distanceRange) / texSize;
    float2 duv = max(fwidth(in.uv), float2(1e-6));
    float2 screenTexSize = 1.0 / duv;
    float screenPxRange = max(0.5 * dot(unitRange, screenTexSize), 1.0);
    TextDistance distance;
    distance.msdfPxDist = sd * screenPxRange;
    distance.sdfPxDist = sdf * screenPxRange;
    distance.screenPxRange = screenPxRange;
    return distance;
}

static half4 shadeGlyph(TextDistance distance,
                        float fillPxDist,
                        float strokeWidthPx,
                        constant TextStyle& style,
                        float vertexAlpha) {
    half fill = half(smoothstep(-0.5, 0.5, fillPxDist));
    half outer = half(smoothstep(-strokeWidthPx - 0.5, -strokeWidthPx + 0.5, distance.sdfPxDist));
    half stroke = clamp(outer - fill, 0.0h, 1.0h);

    half coverage = clamp(fill + stroke, 0.0h, 1.0h);
    half alpha = coverage * half(vertexAlpha);
    half3 color = (fill * half3(style.textColor) + stroke * half3(style.strokeColor))
        / max(coverage, 1.0e-4h);
    return half4(color, alpha);
}

fragment half4 textFragment(VertexOut in [[stage_in]],
                            texture2d<half> atlasTexture [[texture(0)]],
                            constant TextStyle& style [[buffer(0)]]
                            ) {
    TextDistance distance = computeTextDistance(in, atlasTexture);

    const float boldBiasPx = 0.75;
    // Point labels sit on textured terrain, so keep the halo narrow enough
    // that large style values cannot fill the glyph quad.
    float maxStrokePx = max(0.5 * distance.screenPxRange - 0.5, 0.0);
    float strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    return shadeGlyph(distance,
                      distance.msdfPxDist + boldBiasPx,
                      strokeWidthPx,
                      style,
                      in.alpha);
}

fragment half4 roadTextFragment(VertexOut in [[stage_in]],
                                texture2d<half> atlasTexture [[texture(0)]],
                                constant TextStyle& style [[buffer(0)]]
                                ) {
    TextDistance distance = computeTextDistance(in, atlasTexture);

    const float fillBiasPx = 0.75;
    // Road labels need a less aggressive clamp than point labels: the generic
    // half-range cap can collapse the outline to zero on rotated thin glyphs.
    // Keep a small guaranteed stroke, but stay within the signed-distance support.
    float maxStrokePx = max(distance.screenPxRange - 0.75, 0.75);
    float strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    return shadeGlyph(distance,
                      distance.msdfPxDist + fillBiasPx,
                      strokeWidthPx,
                      style,
                      in.alpha);
}
