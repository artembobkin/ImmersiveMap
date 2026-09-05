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
// the same plane, and every one of them used to sample the shadow map again
// for the same pixel: over a street that is four to six shadow lookups, and
// everything under a building on top of that. The plane is the same for
// every layer, so its shadow is a function of the pixel alone.
// This pass evaluates it once and the ground layers read the result with
// one texture read (see the kGroundShadowMaskEnabled path in Tile.metal).
//
// Receivers with geometry of their own (buildings, scene models) keep
// sampling the shadow map per fragment: their surfaces are not the plane.

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

// One fullscreen triangle in clip space; the fragment reconstructs the world
// ray from its own pixel position, so nothing is interpolated.
vertex GroundShadowMaskVertexOut groundShadowMaskVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    GroundShadowMaskVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// Intersects the pixel's view ray with the ground plane and samples the
// shadow window there. Unlike the generic `sampleShadowFactor`, this path
// never needs the normal handling: the plane always faces up, so geometric
// visibility is 1 and the factor reduces to
// 1 - (1 - mapVisibility) * strength * fade. Nothing here takes a screen
// derivative, so control flow is free to diverge: pixels above the horizon
// and pixels beyond the shadow fade return lit without touching the map.
//
// The plane gets no normal offset (it is not a caster, so it cannot shadow
// itself) and no receiver-plane gradient; the constant depthBias alone
// carries the contact zone at the base of a building, which is the only
// place the ground's own depth is compared against a caster's.
fragment half groundShadowMaskFragmentShader(GroundShadowMaskVertexOut in [[stage_in]],
                                             constant GroundShadowMaskUniform& mask [[buffer(0)]],
                                             constant Shadow& shadow [[buffer(1)]],
                                             depth2d<float> shadowMap [[texture(0)]]) {
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

    // Orthographic light projection: w is 1, no divide.
    float3 uvz = (shadow.cascade.worldToShadowTexture * float4(worldPosition, 1.0)).xyz;
    float mapVisibility = shadowWindowContains(shadow.cascade, uvz)
        ? shadowWindowVisibility(shadow.cascade, shadowMap, uvz)
        : 1.0;

    float fade = 1.0 - smoothstep(shadow.fadeStartDistance, shadow.fadeEndDistance, distanceToEye);
    return half(1.0 - (1.0 - mapVisibility) * shadow.strength * fade);
}
