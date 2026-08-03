// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderUniforms.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;

#ifndef RENDER_UNIFORMS
#define RENDER_UNIFORMS

struct Camera {
    float4x4 matrix;
    float3 eye;
    float _padding;
};

struct Globe {
    float panX;
    float panY;
    float radius;
    float transition;
};

struct EarthScene {
    float3 sunDirection;
    uint isEnabled;
    float daySideMinimumBrightness;
    float nightSideBrightness;
    float terminatorFadeWidth;
    uint sunVisualEnabled;
    float sunDiskAngularSize;
    float sunDiskIntensity;
    float sunGlowIntensity;
    float sunEdgeGlareIntensity;
    float sunLimbHaloIntensity;
    float sunLimbHaloWidth;
    float sunShadowFade;
    uint _padding0;
};

struct SunVisualState {
    float2 screenCenter;
    float2 clampedScreenCenter;
    float2 globeScreenCenter;
    float globeScreenRadius;
    float diskAlpha;
    float edgeGlareAlpha;
    float limbHaloAlpha;
    uint isEnabled;
    uint padding;
};

// One shadow cascade; the layout mirrors ShadowCascadeUniform.swift (pinned
// by ShadowUniformLayoutTests). worldToShadowTexture maps world space straight
// to the cascade's half of the 2:1 shadow atlas: xy = atlas UV, z = depth.
struct ShadowCascade {
    float4x4 worldToShadowTexture;
    // Poisson kernel radius in atlas UV per axis; zero = single bilinear tap
    // (the crisp near cascade).
    float2 kernelRadiusUV;
    float depthBias;
    // Cap for the receiver-plane depth gradient (normalized depth per UV).
    float gradientClamp;
    // Valid atlas-UV rectangle, inset so taps never cross the atlas seam.
    float2 uvMinimum;
    float2 uvMaximum;
    // World-space normal-offset distance for receivers with normals
    // (~1.5 texels of this cascade, meter-capped).
    float normalOffsetWorld;
    float _padding0;
    // One cascade texel in atlas UV, for the per-tap slope bias.
    float2 texelSizeUV;
};

// Directional shadow sampling parameters; the layout mirrors ShadowUniform.swift.
struct Shadow {
    ShadowCascade cascades[2]; // [near (crisp), far (soft)]
    float3 eye;
    float strength;
    float fadeStartDistance;
    float fadeEndDistance;
    float _padding;
    // Normalized direction towards the static sun, for the geometric
    // self-shadow test of receivers that have normals.
    float3 lightDirection;
};

// Receiver-plane depth gradient dz/duv from screen-space derivatives
// (Isidoro). Must run in uniform control flow, before any divergent early-out.
// The clamp value is expressed for the u axis; one atlas-V spans half the
// world of one atlas-U (the cascade half is square but covers 0.5 of u and
// 1.0 of v), so the same slope cap on v is half the u value.
static inline float2 shadowReceiverGradient(float3 uvz, float gradientClamp) {
    float2 duvdx = dfdx(uvz.xy);
    float2 duvdy = dfdy(uvz.xy);
    float dzdx = dfdx(uvz.z);
    float dzdy = dfdy(uvz.z);
    float det = duvdx.x * duvdy.y - duvdx.y * duvdy.x;
    float2 dzduv = float2(0.0);
    if (abs(det) > 1e-12) {
        dzduv = float2(duvdy.y * dzdx - duvdx.y * dzdy,
                       duvdx.x * dzdy - duvdy.x * dzdx) / det;
    }
    float2 axisClamp = float2(gradientClamp, gradientClamp * 0.5);
    return clamp(dzduv, -axisClamp, axisClamp);
}

static inline bool shadowCascadeContains(constant ShadowCascade& cascade, float3 uvz) {
    return uvz.x >= cascade.uvMinimum.x && uvz.x <= cascade.uvMaximum.x &&
           uvz.y >= cascade.uvMinimum.y && uvz.y <= cascade.uvMaximum.y &&
           uvz.z >= 0.0 && uvz.z <= 1.0;
}

// One cascade's visibility. Zero kernel radius = a single hardware-bilinear
// compare: the crisp ~1-texel edge of the near cascade. Otherwise a 12-tap
// Poisson PCF; every tap is compared against the receiver-plane depth
// predicted from the gradient, so flat surfaces (roofs, ground) need almost
// no constant bias — no acne striping and no contact detachment.
static inline float shadowCascadeVisibility(constant ShadowCascade& cascade,
                                            depth2d<float> shadowMap,
                                            float3 uvz,
                                            float2 dzduv) {
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    mip_filter::none,
                                    address::clamp_to_edge,
                                    compare_func::less_equal);
    // The receiver-plane term corrects each tap CENTER, but a hardware
    // bilinear compare shares one reference across four texels whose stored
    // depths differ by up to a texel of receiver slope — on steep receivers
    // (oblique walls, roofs under a low sun) that alone stripes. Cover the
    // within-tap footprint with a slope-proportional bias from the actual
    // gradient.
    float slopeBias = 0.71 * (abs(dzduv.x) * cascade.texelSizeUV.x
                              + abs(dzduv.y) * cascade.texelSizeUV.y);
    float bias = cascade.depthBias + slopeBias;

    if (cascade.kernelRadiusUV.x <= 0.0) {
        return shadowMap.sample_compare(shadowSampler, uvz.xy, uvz.z - bias);
    }

    constexpr float2 poissonTaps[12] = {
        float2(-0.326, -0.406), float2(-0.840, -0.074),
        float2(-0.696, 0.457), float2(-0.203, 0.621),
        float2(0.962, -0.195), float2(0.473, -0.480),
        float2(0.519, 0.767), float2(0.185, -0.893),
        float2(0.507, 0.064), float2(0.896, 0.412),
        float2(-0.322, -0.933), float2(-0.792, -0.598)
    };
    float visibility = 0.0;
    for (int i = 0; i < 12; ++i) {
        float2 offset = poissonTaps[i] * cascade.kernelRadiusUV;
        float planeDepth = uvz.z + dot(dzduv, offset);
        visibility += shadowMap.sample_compare(shadowSampler,
                                               uvz.xy + offset,
                                               planeDepth - bias);
    }
    return visibility * (1.0 / 12.0);
}

// Shadow visibility factor in [1 - strength, 1]; 1 = fully lit.
//
// `surfaceNormal` is the receiver's (unnormalized) world normal, or zero for
// receivers without one (the ground plane, which always faces the sun). For
// normal-bearing receivers three defenses compose:
//  * the normal is flipped towards the camera first (two-sided test) — map
//    data contains inverted-winding buildings that render fine as opaque
//    boxes but carry inward normals;
//  * geometric self-shadow: a face turned away from the sun is in shadow by
//    definition (no map lookup is needed or trusted there), with a narrow
//    smoothstep band at grazing angles where the wall's map footprint is
//    sub-texel and unreliable;
//  * normal-offset sampling: the sample point shifts off the surface along
//    the normal by ~1.5 cascade texels, so a lit face cannot stripe against
//    its own quantized depth record, while real occluders — meters away —
//    still shadow it.
//
// Cascade selection by containment: the near (crisp) cascade wins wherever
// its window covers the point, the far cascade picks up the rest, and
// anything outside both is lit — the horizon backdrop stays clean by
// construction, and the eye-distance fade hides the far coverage edge.
//
// Must be called from uniform control flow (derivatives): callers multiply
// the result into their color instead of branching around the call.
static inline float sampleShadowFactor(constant Shadow& shadow,
                                       depth2d<float> shadowMap,
                                       float3 worldPos,
                                       float3 surfaceNormal) {
    float normalLength = length(surfaceNormal);
    float hasNormal = normalLength > 1e-5 ? 1.0 : 0.0;
    float3 normal = surfaceNormal / max(normalLength, 1e-5);
    // Two-sided flip with hysteresis: strictly back-facing normals (inverted
    // winding) flip towards the camera, but interpolated normals grazing past
    // perpendicular at curved silhouettes must not toggle per frame.
    float3 towardsCamera = shadow.eye - worldPos;
    if (dot(normal, towardsCamera) < -0.05 * length(towardsCamera)) {
        normal = -normal;
    }
    normal *= hasNormal;
    // Hard lower cutoff aligned with the gradient clamp: a wall with
    // N·L < 0.125 has depth slope above what the clamped receiver-plane can
    // represent (slope 8 at N·L = 1/sqrt(65)), so it never reaches the map —
    // it is declared geometrically self-shadowed instead of striping.
    float geometricVisibility = hasNormal > 0.0
        ? smoothstep(0.125, 0.25, dot(normal, shadow.lightDirection))
        : 1.0;

    float3 positionNear = worldPos + normal * shadow.cascades[0].normalOffsetWorld;
    float3 positionFar = worldPos + normal * shadow.cascades[1].normalOffsetWorld;
    float4 projectedNear = shadow.cascades[0].worldToShadowTexture * float4(positionNear, 1.0);
    float4 projectedFar = shadow.cascades[1].worldToShadowTexture * float4(positionFar, 1.0);
    float3 uvzNear = projectedNear.xyz / projectedNear.w;
    float3 uvzFar = projectedFar.xyz / projectedFar.w;
    float2 gradientNear = shadowReceiverGradient(uvzNear, shadow.cascades[0].gradientClamp);
    float2 gradientFar = shadowReceiverGradient(uvzFar, shadow.cascades[1].gradientClamp);

    if (shadow.strength <= 0.0) {
        return 1.0;
    }

    float visibility = 1.0;
    if (geometricVisibility <= 0.0) {
        visibility = 0.0;
    } else if (shadowCascadeContains(shadow.cascades[0], uvzNear)) {
        visibility = geometricVisibility
            * shadowCascadeVisibility(shadow.cascades[0], shadowMap, uvzNear, gradientNear);
    } else if (shadowCascadeContains(shadow.cascades[1], uvzFar)) {
        visibility = geometricVisibility
            * shadowCascadeVisibility(shadow.cascades[1], shadowMap, uvzFar, gradientFar);
    } else {
        visibility = geometricVisibility;
    }

    float distanceToEye = length(worldPos - shadow.eye);
    float fade = 1.0 - smoothstep(shadow.fadeStartDistance, shadow.fadeEndDistance, distanceToEye);
    return 1.0 - (1.0 - visibility) * shadow.strength * fade;
}

// Haze at the horizon of the flat presentation; the layout mirrors
// HorizonFogUniform.swift. Distances are measured in eye heights above the
// plane, so the fog band is geometrically glued to the vanishing line and
// depends neither on zoom nor on render-scale changes at integer zooms.
struct HorizonFog {
    float3 color;
    float3 eye;
    float strength;
    float startEyeHeights;
    float endEyeHeights;
    float _padding;
};

static inline float3 applyHorizonFog(float3 color,
                                     constant HorizonFog& fog,
                                     float3 worldPos) {
    float eyeHeight = max(abs(fog.eye.z), 1e-4);
    float distanceToEye = length(worldPos - fog.eye);
    float fogAmount = smoothstep(fog.startEyeHeights * eyeHeight,
                                 fog.endEyeHeights * eyeHeight,
                                 distanceToEye) * fog.strength;
    return mix(color, fog.color, fogAmount);
}

#endif
