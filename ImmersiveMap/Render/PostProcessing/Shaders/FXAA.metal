// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

struct PostProcessingVertexOut {
    float4 position [[position]];
    float2 uv;
};

// The pass itself is planned only when FXAA is enabled (RenderPassGraph), so
// the shader carries no enabled flag.
struct FXAAUniform {
    float2 inverseViewportSize;
};

vertex PostProcessingVertexOut postProcessingVertexShader(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    PostProcessingVertexOut out;
    float2 clip = positions[vertexID];
    out.position = float4(clip, 0.0, 1.0);
    out.uv = float2(clip.x * 0.5 + 0.5, 0.5 - clip.y * 0.5);
    return out;
}

// Luma and color math runs in half: the source is an 8-bit target, so half's
// precision exceeds what the samples carry. UV offsets stay float, texel
// steps are far below half's normal range.
fragment half4 fxaaFragmentShader(PostProcessingVertexOut in [[stage_in]],
                                  texture2d<half> sourceTexture [[texture(0)]],
                                  constant FXAAUniform& uniform [[buffer(0)]]) {
    constexpr sampler sourceSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);

    // Alpha is carried through instead of being forced to 1: with transparent
    // space the frame alpha is the map's coverage mask, and the window server
    // composites the drawable over the app's own background with it.
    half4 centerSample = sourceTexture.sample(sourceSampler, in.uv);
    half3 center = centerSample.rgb;
    float2 texel = uniform.inverseViewportSize;
    half3 nw = sourceTexture.sample(sourceSampler, in.uv + texel * float2(-1.0, -1.0)).rgb;
    half3 ne = sourceTexture.sample(sourceSampler, in.uv + texel * float2(1.0, -1.0)).rgb;
    half3 sw = sourceTexture.sample(sourceSampler, in.uv + texel * float2(-1.0, 1.0)).rgb;
    half3 se = sourceTexture.sample(sourceSampler, in.uv + texel * float2(1.0, 1.0)).rgb;

    const half3 lumaWeights = half3(0.299h, 0.587h, 0.114h);
    half lumaNW = dot(nw, lumaWeights);
    half lumaNE = dot(ne, lumaWeights);
    half lumaSW = dot(sw, lumaWeights);
    half lumaSE = dot(se, lumaWeights);
    half lumaM = dot(center, lumaWeights);

    half lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    half lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

    half2 direction;
    direction.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
    direction.y = ((lumaNW + lumaSW) - (lumaNE + lumaSE));

    half directionReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * 0.03125h, 0.0078125h);
    half inverseDirectionAdjustment = 1.0h / (min(abs(direction.x), abs(direction.y)) + directionReduce);
    float2 sampleStep = clamp(float2(direction * inverseDirectionAdjustment),
                              float2(-8.0), float2(8.0)) * texel;

    // The blend runs on the full RGBA: the colors are premultiplied, so the
    // same weights smooth the coverage mask and the color together and the
    // globe limb keeps a matching antialiased edge in both.
    half4 resultA = 0.5h * (
        sourceTexture.sample(sourceSampler, in.uv + sampleStep * (1.0 / 3.0 - 0.5)) +
        sourceTexture.sample(sourceSampler, in.uv + sampleStep * (2.0 / 3.0 - 0.5))
    );
    half4 resultB = resultA * 0.5h + 0.25h * (
        sourceTexture.sample(sourceSampler, in.uv + sampleStep * -0.5) +
        sourceTexture.sample(sourceSampler, in.uv + sampleStep * 0.5)
    );

    half lumaB = dot(resultB.rgb, lumaWeights);
    return (lumaB < lumaMin || lumaB > lumaMax) ? resultA : resultB;
}
