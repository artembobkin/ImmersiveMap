// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeSurfaceLighting.metal
//  ImmersiveMap
//
//  The globe surface's lighting as one deferred fullscreen pass. On the pure
//  sphere at the plain palette (transition 0, tone depth 0, fog strength 0)
//  everything `globeSurfaceShade` does to a colour is affine: the day/night
//  factor multiplies, the rim light and the limb glow add, and an affine
//  transform commutes exactly with alpha blending. The ground layers can
//  therefore blend unlit, and this pass applies the light once per pixel:
//  it outputs the additive term in rgb and the multiplier in alpha, and the
//  fixed-function blend (dst.rgb * src.a + src.rgb) does the arithmetic per
//  sample. The pixel's place on the sphere is resolved analytically from
//  the view ray, the way the atmosphere halo and the ground shadow mask
//  already do, so no geometry is re-rasterized and nothing is stored.
//
//  Drawn at the far plane, depth-tested with `greater`: only pixels whose
//  depth the placeholder grid wrote (the sphere) pass; space stays
//  untouched for the sky that draws after. The polar caps write no depth
//  and draw later, lit inline as always.
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"
#include "GlobeSurfaceShading.h"

/// Per-frame parameters; the layout mirrors GlobeSurfaceLightingUniform.swift
/// (pinned by GlobeSurfaceLightingUniformLayoutTests).
struct GlobeSurfaceLighting {
    float4x4 inverseViewProjection;
    float3 eye;
    float3 center;
    /// The earth-fixed sun carried into world space through the globe's
    /// rotation (dot products against world-space normals equal the
    /// earth-frame ones, the rotation being orthonormal), or zero when the
    /// earth scene is off.
    float3 worldSunDirection;
    float radius;
};

struct GlobeSurfaceLightingVertexOut {
    float4 position [[position]];
    float2 ndc;
};

vertex GlobeSurfaceLightingVertexOut globeSurfaceLightingVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    GlobeSurfaceLightingVertexOut out;
    // The far plane: the greater depth test keeps exactly the pixels the
    // globe surface wrote its depth to, and rejects space.
    out.position = float4(positions[vertexID], 1.0, 1.0);
    out.ndc = positions[vertexID];
    return out;
}

fragment half4 globeSurfaceLightingFragmentShader(GlobeSurfaceLightingVertexOut in [[stage_in]],
                                                  constant GlobeSurfaceLighting& lighting [[buffer(0)]],
                                                  constant EarthScene& earthScene [[buffer(1)]],
                                                  constant GlobeAtmosphere& atmosphere [[buffer(2)]]) {
    // The view ray through this pixel, exactly as the atmosphere halo builds
    // it: unproject the far-plane point and aim at it from the eye.
    float4 farPoint = lighting.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 direction = normalize(farPoint.xyz / farPoint.w - lighting.eye);
    float3 eyeFromCenter = lighting.eye - lighting.center;
    float radius = max(lighting.radius, 1e-6);
    // Nearest intersection of the ray with the sphere. Every pixel that
    // passed the depth test lies on the grid's chords, which sag inside the
    // true sphere, so the ray hits it; the guard covers float noise at the
    // very silhouette by falling back to the closest approach.
    float along = dot(direction, eyeFromCenter);
    float discriminant = along * along - (dot(eyeFromCenter, eyeFromCenter) - radius * radius);
    float travel = -along - sqrt(max(discriminant, 0.0));
    float3 worldPos = lighting.eye + direction * travel;
    float3 normal = normalize(worldPos - lighting.center);
    float3 viewDir = -direction;
    half facingDot = half(dot(normal, viewDir));

    // The affine pieces of globeSurfaceShade at transition 0 and tone depth
    // 0, term for term and in the same precision: the brightness that
    // multiplies the surface colour, and the light that adds to it.
    half brightness = 1.0h;
    half3 additive = half3(0.0h);
    if (earthScene.isEnabled != 0) {
        half sunDot = half(dot(normal, lighting.worldSunDirection));
        half terminatorFadeWidth = half(earthScene.terminatorFadeWidth);
        half dayFactor = smoothstep(-terminatorFadeWidth,
                                    terminatorFadeWidth,
                                    sunDot);
        half dayBrightness = mix(half(earthScene.daySideMinimumBrightness), 1.0h, dayFactor);
        half surfaceBrightness = mix(half(earthScene.nightSideBrightness), dayBrightness, dayFactor);
        surfaceBrightness = mix(surfaceBrightness, 1.0h, half(earthScene.sunShadowFade));
        brightness = surfaceBrightness;
        half rim = pow(max(0.0h, 1.0h - facingDot), 4.0h);
        half dawnBand = smoothstep(-0.10h, 0.12h, sunDot) * (1.0h - smoothstep(0.30h, 0.70h, sunDot));
        half forward = smoothstep(0.0h, 0.45h, half(-dot(atmosphere.sunDirection, viewDir)));
        half rimLight = rim * dawnBand * forward
            * (1.0h - half(earthScene.sunShadowFade))
            * half(atmosphere.intensity);
        additive += half3(1.0h, 0.80h, 0.55h) * rimLight * 0.7h;
    }
    half facing = max(0.0h, 1.0h - facingDot);
    additive += globeAtmosphereSurfaceGlow(facing, atmosphere);
    return half4(additive, brightness);
}
