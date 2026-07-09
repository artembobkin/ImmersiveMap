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

float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

static TextDistance computeTextDistance(VertexOut in,
                                        texture2d<float> atlasTexture) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 atlasSample = atlasTexture.sample(textureSampler, in.uv);
    float3 msdf = atlasSample.rgb;
    float sd = median(msdf.r, msdf.g, msdf.b) - 0.5;
    float sdf = atlasSample.a - 0.5;
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

fragment float4 textFragment(VertexOut in [[stage_in]],
                             texture2d<float> atlasTexture [[texture(0)]],
                             constant TextStyle& style [[buffer(0)]]
                             ) {
    TextDistance distance = computeTextDistance(in, atlasTexture);

    const float boldBiasPx = 0.75;
    float fill = smoothstep(-0.5, 0.5, distance.msdfPxDist + boldBiasPx);
    // Point labels sit on textured terrain, so keep the halo narrow enough
    // that large style values cannot fill the glyph quad.
    float maxStrokePx = max(0.5 * distance.screenPxRange - 0.5, 0.0);
    float strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    float outer = smoothstep(-strokeWidthPx - 0.5, -strokeWidthPx + 0.5, distance.sdfPxDist);
    float stroke = clamp(outer - fill, 0.0, 1.0);

    float coverage = clamp(fill + stroke, 0.0, 1.0);
    float alpha = coverage * in.alpha;
    float3 color = (fill * style.textColor + stroke * style.strokeColor) / max(coverage, 1e-5);
    return float4(color, alpha);
}

fragment float4 roadTextFragment(VertexOut in [[stage_in]],
                                 texture2d<float> atlasTexture [[texture(0)]],
                                 constant TextStyle& style [[buffer(0)]]
                                 ) {
    TextDistance distance = computeTextDistance(in, atlasTexture);

    const float fillBiasPx = 0.75;
    float fill = smoothstep(-0.5, 0.5, distance.msdfPxDist + fillBiasPx);

    // Road labels need a less aggressive clamp than point labels: the generic
    // half-range cap can collapse the outline to zero on rotated thin glyphs.
    // Keep a small guaranteed stroke, but stay within the signed-distance support.
    float maxStrokePx = max(distance.screenPxRange - 0.75, 0.75);
    float strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    float outer = smoothstep(-strokeWidthPx - 0.5, -strokeWidthPx + 0.5, distance.sdfPxDist);
    float stroke = clamp(outer - fill, 0.0, 1.0);

    float coverage = clamp(fill + stroke, 0.0, 1.0);
    float alpha = coverage * in.alpha;
    float3 color = (fill * style.textColor + stroke * style.strokeColor) / max(coverage, 1e-5);
    return float4(color, alpha);
}
