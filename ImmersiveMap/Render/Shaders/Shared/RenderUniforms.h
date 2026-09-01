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

/// Per-frame derivatives of Globe, computed once on the CPU instead of once
/// per vertex: the pan rotation (in the row-vector column layout the vertex
/// stages multiply with), the flat morph target's map size and Mercator pan,
/// and the pan angles. Mirrors GlobeFrameConstantsUniform.swift (layout
/// pinned by GlobeSphereVertexPathTests).
struct GlobeFrameConstants {
    float4x4 rotation;
    float mapSize;
    float panMercatorY;
    float panLatitude;
    float panLongitude;
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
// to the cascade's slice of the shadow texture array: xy = slice UV, z = depth;
// the slice index equals the cascade's position in Shadow.cascades.
struct ShadowCascade {
    float4x4 worldToShadowTexture;
    // Reserved (kept for layout stability); the tent PCF filter footprint is
    // fixed at 3x3 texels.
    float2 kernelRadiusUV;
    float depthBias;
    // Cap for the receiver-plane depth gradient (normalized depth per UV).
    float gradientClamp;
    // Valid slice-UV rectangle, inset so taps never leave the fitted window.
    float2 uvMinimum;
    float2 uvMaximum;
    // World-space normal-offset distance for receivers with normals
    // (~1.5 texels of this cascade, meter-capped).
    float normalOffsetWorld;
    float _padding0;
    // One cascade texel in slice UV, for the per-tap slope bias.
    float2 texelSizeUV;
};

// Light matrices of the caster pass, one per cascade; the layout mirrors
// ShadowCasterUniform.swift (pinned by ShadowUniformLayoutTests). The caster
// vertex stages index it by [[instance_id]] and route the result to the
// matching array slice via [[render_target_array_index]], so all cascades
// render in one pass with one draw per geometry.
struct ShadowCasterMatrices {
    float4x4 lightProjectionViews[3];
};

// Directional shadow sampling parameters; the layout mirrors ShadowUniform.swift.
struct Shadow {
    ShadowCascade cascades[3]; // [near, middle, far]
    float3 eye;
    float strength;
    float fadeStartDistance;
    float fadeEndDistance;
    float _padding;
    // Normalized direction towards the static sun, for the geometric
    // self-shadow test of receivers that have normals.
    float3 lightDirection;
    // RGB cast of a fully shadowed surface on top of the strength darkening:
    // white keeps the neutral darkening, a bluish tint gives shadows the cool
    // cast of light coming only from the sky.
    float3 tint;
};

// The glow of the globe's atmosphere on the sphere surface toward the limb;
// the layout mirrors GlobeAtmosphereUniform.swift. Zero intensity leaves the
// surface bare (the atmosphere is off).
struct GlobeAtmosphere {
    float3 color;
    float intensity;
    float3 sunDirection;
    float _padding0;
};

// Receiver-plane depth gradient dz/duv from screen-space derivatives
// (Isidoro). Must run in uniform control flow, before any divergent early-out.
// The clamp value is expressed for the u axis; the same world slope maps to a
// v gradient scaled by the atlas texel aspect (texels are square in world),
// so the v clamp scales by texelSizeUV.x / texelSizeUV.y.
static inline float2 shadowReceiverGradient(constant ShadowCascade& cascade, float3 uvz) {
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
    float aspect = cascade.texelSizeUV.x / max(cascade.texelSizeUV.y, 1e-9);
    float2 axisClamp = cascade.gradientClamp * float2(1.0, aspect);
    return clamp(dzduv, -axisClamp, axisClamp);
}

static inline bool shadowCascadeContains(constant ShadowCascade& cascade, float3 uvz) {
    return uvz.x >= cascade.uvMinimum.x && uvz.x <= cascade.uvMaximum.x &&
           uvz.y >= cascade.uvMinimum.y && uvz.y <= cascade.uvMaximum.y &&
           uvz.z >= 0.0 && uvz.z <= 1.0;
}

// One cascade's visibility: Castaño's 3x3 tent PCF (The Witness): four
// hardware-bilinear compares with computed weights reconstruct a C1 tent
// kernel. A plain bilinear tap is exact along the shadow-grid axes but
// staircases on diagonal edges (the far shadow boundary cast by roof edges is
// almost always diagonal to the grid); the tent gives the same ~2-texel crisp
// ramp in EVERY orientation. Every tap is compared against the receiver-plane
// depth predicted from the gradient, so flat surfaces (roofs, ground) need
// almost no constant bias: no acne striping and no contact detachment.
static inline float shadowCascadeVisibility(constant ShadowCascade& cascade,
                                            depth2d_array<float> shadowMap,
                                            uint cascadeIndex,
                                            float3 uvz,
                                            float2 dzduv) {
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    mip_filter::none,
                                    address::clamp_to_edge,
                                    compare_func::less_equal);
    // The receiver-plane term corrects each tap CENTER, but a hardware
    // bilinear compare shares one reference across four texels whose stored
    // depths differ by up to a texel of receiver slope; on steep receivers
    // (oblique walls, roofs under a low sun) that alone stripes. Cover the
    // within-tap footprint with a slope-proportional bias from the actual
    // gradient.
    float slopeBias = 0.71 * (abs(dzduv.x) * cascade.texelSizeUV.x
                              + abs(dzduv.y) * cascade.texelSizeUV.y);
    float bias = cascade.depthBias + slopeBias;

    // Tent weights/offsets in texel space; conversions go through texelSizeUV.
    float2 texelCoords = uvz.xy / cascade.texelSizeUV;
    float2 base = floor(texelCoords + 0.5);
    float s = texelCoords.x + 0.5 - base.x;
    float t = texelCoords.y + 0.5 - base.y;
    float2 baseUV = (base - 0.5) * cascade.texelSizeUV;

    float uw0 = 3.0 - 2.0 * s;
    float uw1 = 1.0 + 2.0 * s;
    float u0 = (2.0 - s) / uw0 - 1.0;
    float u1 = s / uw1 + 1.0;
    float vw0 = 3.0 - 2.0 * t;
    float vw1 = 1.0 + 2.0 * t;
    float v0 = (2.0 - t) / vw0 - 1.0;
    float v1 = t / vw1 + 1.0;

    float visibility = 0.0;
    float2 tapUV;
    tapUV = baseUV + float2(u0, v0) * cascade.texelSizeUV;
    visibility += uw0 * vw0 * shadowMap.sample_compare(shadowSampler, tapUV, cascadeIndex,
        uvz.z + dot(dzduv, tapUV - uvz.xy) - bias);
    tapUV = baseUV + float2(u1, v0) * cascade.texelSizeUV;
    visibility += uw1 * vw0 * shadowMap.sample_compare(shadowSampler, tapUV, cascadeIndex,
        uvz.z + dot(dzduv, tapUV - uvz.xy) - bias);
    tapUV = baseUV + float2(u0, v1) * cascade.texelSizeUV;
    visibility += uw0 * vw1 * shadowMap.sample_compare(shadowSampler, tapUV, cascadeIndex,
        uvz.z + dot(dzduv, tapUV - uvz.xy) - bias);
    tapUV = baseUV + float2(u1, v1) * cascade.texelSizeUV;
    visibility += uw1 * vw1 * shadowMap.sample_compare(shadowSampler, tapUV, cascadeIndex,
        uvz.z + dot(dzduv, tapUV - uvz.xy) - bias);
    return visibility * (1.0 / 16.0);
}

// Shadow visibility factor in [1 - strength, 1]; 1 = fully lit.
//
// `surfaceNormal` is the receiver's (unnormalized) world normal, or zero for
// receivers without one (the ground plane, which always faces the sun). For
// normal-bearing receivers three defenses compose:
//  * the normal is flipped towards the camera first (two-sided test): building
//    walls arrive outward-facing from the parser, but scene-model assets and
//    the inner walls of clip-substituted buildings can still face away;
//  * geometric self-shadow: a face turned away from the sun is in shadow by
//    definition (no map lookup is needed or trusted there), with a narrow
//    smoothstep band at grazing angles where the wall's map footprint is
//    sub-texel and unreliable;
//  * normal-offset sampling: the sample point shifts off the surface along
//    the normal by ~1.5 cascade texels, so a lit face cannot stripe against
//    its own quantized depth record, while real occluders (meters away)
//    still shadow it.
//
// Cascade selection by containment: the near (crisp) cascade wins wherever
// its window covers the point, the far cascade picks up the rest, and
// anything outside both is lit, so the horizon backdrop stays clean by
// construction, and the eye-distance fade hides the far coverage edge.
//
// Must be called from uniform control flow (derivatives): callers multiply
// the result into their color instead of branching around the call.
static inline float sampleShadowFactor(constant Shadow& shadow,
                                       depth2d_array<float> shadowMap,
                                       float3 worldPos,
                                       float3 surfaceNormal) {
    // Disabled shadows exit before any cascade math. The condition reads a
    // constant-buffer value, so every fragment of the draw takes the same
    // branch and control flow stays uniform for the derivatives below.
    if (shadow.strength <= 0.0) {
        return 1.0;
    }

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
    // represent (slope 8 at N·L = 1/sqrt(65)), so it never reaches the map,
    // it is declared geometrically self-shadowed instead of striping.
    float geometricVisibility = hasNormal > 0.0
        ? smoothstep(0.125, 0.25, dot(normal, shadow.lightDirection))
        : 1.0;

    // All cascade projections and their derivatives are evaluated before any
    // divergent selection (uniform control flow).
    float3 uvzs[3];
    float2 gradients[3];
    for (int i = 0; i < 3; ++i) {
        float3 position = worldPos + normal * shadow.cascades[i].normalOffsetWorld;
        float4 projected = shadow.cascades[i].worldToShadowTexture * float4(position, 1.0);
        uvzs[i] = projected.xyz / projected.w;
        gradients[i] = shadowReceiverGradient(shadow.cascades[i], uvzs[i]);
    }

    float mapVisibility = 1.0;
    if (geometricVisibility > 0.0) {
        for (int i = 0; i < 3; ++i) {
            if (shadowCascadeContains(shadow.cascades[i], uvzs[i])) {
                float cascadeVisibility = shadowCascadeVisibility(shadow.cascades[i], shadowMap,
                                                                  uint(i), uvzs[i], gradients[i]);
                // Cross-fade to the next cascade near this window's edge.
                // The cascade windows are anchored at the camera's look-at
                // point, so panning drives content through them: with a hard
                // containment switch the sharp-to-coarse texel boundary sweeps
                // across facades and reads as the shadow edge crawling along
                // the wall during fast movement. Blending over a few texels
                // turns that traveling seam into a gradual, invisible change.
                float2 uv = uvzs[i].xy;
                float2 distanceToMin = uv - shadow.cascades[i].uvMinimum;
                float2 distanceToMax = shadow.cascades[i].uvMaximum - uv;
                float edgeDistance = min(min(distanceToMin.x, distanceToMin.y),
                                         min(distanceToMax.x, distanceToMax.y));
                float blendBand = 8.0 * max(shadow.cascades[i].texelSizeUV.x,
                                            shadow.cascades[i].texelSizeUV.y);
                if (i + 1 < 3 && edgeDistance < blendBand
                    && shadowCascadeContains(shadow.cascades[i + 1], uvzs[i + 1])) {
                    float nextVisibility = shadowCascadeVisibility(shadow.cascades[i + 1], shadowMap,
                                                                   uint(i + 1), uvzs[i + 1], gradients[i + 1]);
                    cascadeVisibility = mix(nextVisibility, cascadeVisibility,
                                            saturate(edgeDistance / blendBand));
                }
                mapVisibility = cascadeVisibility;
                break;
            }
        }
    }

    // A geometrically self-shadowed wall is lit by the sky, so it darkens to
    // only a fraction of the shadow strength; occluded spots the shadow map
    // finds (cast shadows) keep the full strength. The two components blend
    // smoothly across the N·L transition band.
    const float selfShadowStrengthFraction = 0.35;
    float selfShadowAmount = (1.0 - geometricVisibility) * selfShadowStrengthFraction;
    float castShadowAmount = geometricVisibility * (1.0 - mapVisibility);
    float shadowAmount = min(1.0, selfShadowAmount + castShadowAmount);

    float distanceToEye = length(worldPos - shadow.eye);
    float fade = 1.0 - smoothstep(shadow.fadeStartDistance, shadow.fadeEndDistance, distanceToEye);
    return 1.0 - shadowAmount * shadow.strength * fade;
}

// The color multiplier a shadow factor stands for. `sampleShadowFactor` returns
// the neutral darkening 1 - amount * strength; the multiplier recovers the
// amount and mixes the surface toward the tinted fully shadowed multiplier
// (1 - strength) * tint instead of toward plain grey, so a shadowed fragment
// takes on the cast of the sky-lit shadow in proportion to how shadowed it
// is. A white tint reproduces the scalar factor exactly, and disabled shadows
// (zero strength) always yield 1.
static inline float3 shadowColorMultiplier(constant Shadow& shadow, float factor) {
    if (shadow.strength <= 0.0) {
        return float3(1.0);
    }
    float amount = saturate((1.0 - factor) / shadow.strength);
    return mix(float3(1.0), (1.0 - shadow.strength) * shadow.tint, amount);
}

static inline half3 shadowColorMultiplier(constant Shadow& shadow, half factor) {
    return half3(shadowColorMultiplier(shadow, float(factor)));
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

// Half-precision fragment tails: the fog distances stay float (world units
// overflow half), only the final unit-range mix runs in half.
static inline half3 applyHorizonFog(half3 color,
                                    constant HorizonFog& fog,
                                    float3 worldPos) {
    float eyeHeight = max(abs(fog.eye.z), 1e-4);
    float distanceToEye = length(worldPos - fog.eye);
    half fogAmount = half(smoothstep(fog.startEyeHeights * eyeHeight,
                                     fog.endEyeHeights * eyeHeight,
                                     distanceToEye) * fog.strength);
    return mix(color, half3(fog.color), fogAmount);
}

#endif
