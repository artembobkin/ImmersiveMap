// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

struct PostProcessingVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct FXAAUniform {
    float2 inverseViewportSize;
    uint isEnabled;
    uint _padding;
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

fragment float4 fxaaFragmentShader(PostProcessingVertexOut in [[stage_in]],
                                   texture2d<float> sourceTexture [[texture(0)]],
                                   constant FXAAUniform& uniform [[buffer(0)]]) {
    constexpr sampler sourceSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);

    float3 center = sourceTexture.sample(sourceSampler, in.uv).rgb;
    if (uniform.isEnabled == 0) {
        return float4(center, 1.0);
    }

    float2 texel = uniform.inverseViewportSize;
    float3 nw = sourceTexture.sample(sourceSampler, in.uv + texel * float2(-1.0, -1.0)).rgb;
    float3 ne = sourceTexture.sample(sourceSampler, in.uv + texel * float2(1.0, -1.0)).rgb;
    float3 sw = sourceTexture.sample(sourceSampler, in.uv + texel * float2(-1.0, 1.0)).rgb;
    float3 se = sourceTexture.sample(sourceSampler, in.uv + texel * float2(1.0, 1.0)).rgb;

    const float3 lumaWeights = float3(0.299, 0.587, 0.114);
    float lumaNW = dot(nw, lumaWeights);
    float lumaNE = dot(ne, lumaWeights);
    float lumaSW = dot(sw, lumaWeights);
    float lumaSE = dot(se, lumaWeights);
    float lumaM = dot(center, lumaWeights);

    float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

    float2 direction;
    direction.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
    direction.y = ((lumaNW + lumaSW) - (lumaNE + lumaSE));

    float directionReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * 0.03125, 0.0078125);
    float inverseDirectionAdjustment = 1.0 / (min(abs(direction.x), abs(direction.y)) + directionReduce);
    direction = clamp(direction * inverseDirectionAdjustment, float2(-8.0), float2(8.0)) * texel;

    float3 resultA = 0.5 * (
        sourceTexture.sample(sourceSampler, in.uv + direction * (1.0 / 3.0 - 0.5)).rgb +
        sourceTexture.sample(sourceSampler, in.uv + direction * (2.0 / 3.0 - 0.5)).rgb
    );
    float3 resultB = resultA * 0.5 + 0.25 * (
        sourceTexture.sample(sourceSampler, in.uv + direction * -0.5).rgb +
        sourceTexture.sample(sourceSampler, in.uv + direction * 0.5).rgb
    );

    float lumaB = dot(resultB, lumaWeights);
    float3 color = (lumaB < lumaMin || lumaB > lumaMax) ? resultA : resultB;
    return float4(color, 1.0);
}
