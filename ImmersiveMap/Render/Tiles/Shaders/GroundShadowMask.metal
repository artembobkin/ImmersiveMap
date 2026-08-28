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
};

struct GroundShadowMaskVertexOut {
    float4 position [[position]];
};

vertex GroundShadowMaskVertexOut groundShadowMaskVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    GroundShadowMaskVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// Intersects the pixel's view ray with the ground plane and samples the
// cascades there. `sampleShadowFactor` takes screen-space derivatives of the
// projected point, and the neighbours of a ground pixel are ground pixels,
// so the receiver-plane gradient comes out the same as it did for the
// ground geometry. Pixels whose ray misses the plane (above the horizon)
// still run the sampling in uniform control flow, on a clamped point, and
// are then written lit: nothing of the ground is drawn there anyway.
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
    bool hitsGround = abs(denominator) > 1e-12;
    float t = hitsGround ? -rayStart.z / denominator : 0.0;
    hitsGround = hitsGround && t >= 0.0 && t <= 1.0;
    float3 worldPosition = rayStart + rayDirection * clamp(t, 0.0, 1.0);
    worldPosition.z = 0.0;
    float factor = sampleShadowFactor(shadow, shadowMap, worldPosition, float3(0.0));
    return hitsGround ? half(factor) : 1.0h;
}
