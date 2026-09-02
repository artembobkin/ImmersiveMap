// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

// The ground shadow mask: the shadow factor of the flat ground plane (z = 0),
// one value per screen pixel, computed once per frame by a fullscreen pass.
//
// The ground of the flat presentation is a stack of blended layers (the
// landuse fill, then the roads in several roles, then the overlays), all on
// the same plane, and every one of them used to sample the cascades again
// for the same pixel: over a street that is four to six times the tent
// filter, and everything under a building on top of that. The plane is the
// same for every layer, so its shadow is a function of the pixel alone.
// This pass evaluates it once and the ground layers read the result with
// one texture read (see the kGroundShadowMaskEnabled path in Tile.metal).
//
// Receivers with geometry of their own (buildings, scene models) keep
// sampling the cascades per fragment: their surfaces are not the plane.

// The layout mirrors GroundShadowMaskUniform.swift (pinned by
// ShadowUniformLayoutTests).
struct GroundShadowMaskUniform {
    // Inverse of the camera's projection-view: maps Metal NDC (x, y in
    // -1...1, z in 0...1) back to world space.
    float4x4 inverseProjectionView;
    // Mask size in pixels, the same as the drawable.
    float2 viewportSize;
    float2 _padding;
    // Per-cascade receiver-plane gradient of the ground plane, computed
    // analytically on the CPU (the plane is z = 0 and the projections are
    // affine, so it is one constant per cascade). No screen derivatives are
    // needed, so the fragment below is free to exit early.
    float2 planeGradients[3];
    float2 _padding1;
};

struct GroundShadowMaskVertexOut {
    float4 position [[position]];
};

// One hardware-bilinear compare tap: a 2x2 PCF with the same receiver-plane
// bias discipline as the tent kernel. The middle and far cascades read
// through this instead of the 3x3 tent: their texels span meters, the mask
// is sampled at half resolution and bilinearly upsampled by the ground
// layers, so the tent's wider diagonal ramp adds nothing visible there,
// while the near cascade (crisp contact shadows) keeps the full tent.
static inline float groundCascadeSingleTapVisibility(constant ShadowCascade& cascade,
                                                     depth2d_array<float> shadowMap,
                                                     uint cascadeIndex,
                                                     float3 uvz,
                                                     float2 dzduv) {
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    mip_filter::none,
                                    address::clamp_to_edge,
                                    compare_func::less_equal);
    float slopeBias = 0.71 * (abs(dzduv.x) * cascade.texelSizeUV.x
                              + abs(dzduv.y) * cascade.texelSizeUV.y);
    return shadowMap.sample_compare(shadowSampler, uvz.xy, cascadeIndex,
                                    uvz.z - cascade.depthBias - slopeBias);
}

static inline float groundCascadeVisibility(constant ShadowCascade& cascade,
                                            depth2d_array<float> shadowMap,
                                            uint cascadeIndex,
                                            float3 uvz,
                                            float2 dzduv) {
    if (cascadeIndex == 0) {
        return shadowCascadeVisibility(cascade, shadowMap, cascadeIndex, uvz, dzduv);
    }
    return groundCascadeSingleTapVisibility(cascade, shadowMap, cascadeIndex, uvz, dzduv);
}

vertex GroundShadowMaskVertexOut groundShadowMaskVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    GroundShadowMaskVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// Intersects the pixel's view ray with the ground plane and samples the
// cascades there. Unlike the generic `sampleShadowFactor`, this path takes
// no screen-space derivatives: the receiver-plane gradients arrive as
// analytic per-cascade constants (the ground is a plane), so control flow
// is free to diverge. That pays twice: pixels above the horizon and pixels
// beyond the shadow fade return lit before touching a single cascade, and
// the pixels that do sample project only the cascades they actually read
// (the containing one, plus its neighbour inside the edge blend band)
// instead of all three. The math on the sampling path is exactly the
// zero-normal specialization of `sampleShadowFactor`: geometric visibility
// is 1 on the up-facing plane, so the factor reduces to
// 1 - (1 - mapVisibility) * strength * fade.
fragment half groundShadowMaskFragmentShader(GroundShadowMaskVertexOut in [[stage_in]],
                                             constant GroundShadowMaskUniform& mask [[buffer(0)]],
                                             constant Shadow& shadow [[buffer(1)]],
                                             depth2d_array<float> shadowMap [[texture(0)]]) {
    float2 ndc = float2(2.0 * in.position.x / mask.viewportSize.x - 1.0,
                        1.0 - 2.0 * in.position.y / mask.viewportSize.y);
    float4 nearPoint = mask.inverseProjectionView * float4(ndc, 0.0, 1.0);
    float4 farPoint = mask.inverseProjectionView * float4(ndc, 1.0, 1.0);
    float3 rayStart = nearPoint.xyz / nearPoint.w;
    float3 rayEnd = farPoint.xyz / farPoint.w;
    float3 rayDirection = rayEnd - rayStart;
    // Where along the ray the plane lies; negative or past the far plane
    // means the ray never reaches the ground within the view volume.
    float denominator = rayDirection.z;
    if (abs(denominator) <= 1e-12) {
        return 1.0h;
    }
    float t = -rayStart.z / denominator;
    if (t < 0.0 || t > 1.0) {
        return 1.0h;
    }
    float3 worldPosition = rayStart + rayDirection * t;
    worldPosition.z = 0.0;

    if (shadow.strength <= 0.0) {
        return 1.0h;
    }
    float distanceToEye = length(worldPosition - shadow.eye);
    if (distanceToEye >= shadow.fadeEndDistance) {
        return 1.0h;
    }

    float mapVisibility = 1.0;
    for (int i = 0; i < 3; ++i) {
        float4 projected = shadow.cascades[i].worldToShadowTexture * float4(worldPosition, 1.0);
        float3 uvz = projected.xyz / projected.w;
        if (!shadowCascadeContains(shadow.cascades[i], uvz)) {
            continue;
        }
        float cascadeVisibility = groundCascadeVisibility(shadow.cascades[i], shadowMap,
                                                          uint(i), uvz, mask.planeGradients[i]);
        // Cross-fade to the next cascade near this window's edge, exactly
        // like sampleShadowFactor: the sharp-to-coarse texel boundary must
        // not read as a traveling seam during fast movement.
        float2 uv = uvz.xy;
        float2 distanceToMin = uv - shadow.cascades[i].uvMinimum;
        float2 distanceToMax = shadow.cascades[i].uvMaximum - uv;
        float edgeDistance = min(min(distanceToMin.x, distanceToMin.y),
                                 min(distanceToMax.x, distanceToMax.y));
        float blendBand = 8.0 * max(shadow.cascades[i].texelSizeUV.x,
                                    shadow.cascades[i].texelSizeUV.y);
        if (i + 1 < 3 && edgeDistance < blendBand) {
            float4 nextProjected = shadow.cascades[i + 1].worldToShadowTexture * float4(worldPosition, 1.0);
            float3 nextUvz = nextProjected.xyz / nextProjected.w;
            if (shadowCascadeContains(shadow.cascades[i + 1], nextUvz)) {
                float nextVisibility = groundCascadeVisibility(shadow.cascades[i + 1], shadowMap,
                                                               uint(i + 1), nextUvz,
                                                               mask.planeGradients[i + 1]);
                cascadeVisibility = mix(nextVisibility, cascadeVisibility,
                                        saturate(edgeDistance / blendBand));
            }
        }
        mapVisibility = cascadeVisibility;
        break;
    }

    float fade = 1.0 - smoothstep(shadow.fadeStartDistance, shadow.fadeEndDistance, distanceToEye);
    return half(1.0 - (1.0 - mapVisibility) * shadow.strength * fade);
}
