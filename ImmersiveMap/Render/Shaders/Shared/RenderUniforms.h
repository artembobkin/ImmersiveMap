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
/// stages multiply with), the composed sphere matrices, the flat morph
/// target's map size and Mercator pan, the pan angles, and the unroll
/// curvature. Mirrors GlobeFrameConstantsUniform.swift (layout pinned by
/// GlobeSphereVertexPathTests).
struct GlobeFrameConstants {
    float4x4 rotation;
    /// Unit earth direction straight to clip space: camera x translate x
    /// pan rotation x radius, composed on the CPU. Column-vector layout
    /// (multiply as M * v), unlike `rotation`.
    float4x4 sphereClip;
    /// Unit earth direction to the world-space sphere position: translate x
    /// pan rotation x radius. Column-vector layout.
    float4x4 sphereWorld;
    float mapSize;
    float panMercatorY;
    float panLatitude;
    float panLongitude;
    /// The unroll curvature (1 - transition) / radius: the surface lives on
    /// a sphere of radius 1 / curvature tangent to the view centre, and 0
    /// means the plane itself.
    float curvature;
    float3 _padding;
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

// Receiver-plane depth gradient dz/duv, analytically: the receiver is
// treated as the plane through the fragment with its world normal, and the
// cascade projection is affine, so the gradient is an exact per-plane
// constant recovered from two tangents. No screen derivatives are involved
// (the old Isidoro solve took them), which is what frees `sampleShadowFactor`
// to exit early per fragment and to project only the cascade it reads:
// derivative-free code has no uniform-control-flow obligation. At silhouette
// pixels the analytic plane is also exact where derivatives produced clamped
// garbage across the depth discontinuity.
// The clamp value is expressed for the u axis; the same world slope maps to a
// v gradient scaled by the atlas texel aspect (texels are square in world),
// so the v clamp scales by texelSizeUV.x / texelSizeUV.y.
static inline float2 shadowAnalyticGradient(constant ShadowCascade& cascade, float3 planeNormal) {
    float3 axis = abs(planeNormal.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangentA = normalize(cross(planeNormal, axis));
    float3 tangentB = cross(planeNormal, tangentA);

    // Linear part of world -> (u, v, z), row-extracted from the column-major
    // matrix, applied to the two tangents.
    float3 uRow = float3(cascade.worldToShadowTexture[0][0],
                         cascade.worldToShadowTexture[1][0],
                         cascade.worldToShadowTexture[2][0]);
    float3 vRow = float3(cascade.worldToShadowTexture[0][1],
                         cascade.worldToShadowTexture[1][1],
                         cascade.worldToShadowTexture[2][1]);
    float3 zRow = float3(cascade.worldToShadowTexture[0][2],
                         cascade.worldToShadowTexture[1][2],
                         cascade.worldToShadowTexture[2][2]);
    float2 du = float2(dot(uRow, tangentA), dot(uRow, tangentB));
    float2 dv = float2(dot(vRow, tangentA), dot(vRow, tangentB));
    float2 dz = float2(dot(zRow, tangentA), dot(zRow, tangentB));
    float det = du.x * dv.y - du.y * dv.x;
    float2 dzduv = float2(0.0);
    if (abs(det) > 1e-12) {
        dzduv = float2(dv.y * dz.x - dv.x * dz.y,
                       du.x * dz.y - du.y * dz.x) / det;
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
// Derivative-free (the receiver-plane gradient is analytic), so callers may
// branch around the call, and the function itself exits before projecting a
// single cascade for the fragments that need no map: beyond the distance
// fade, or geometrically self-shadowed (a face fully turned from the sun).
static inline float sampleShadowFactor(constant Shadow& shadow,
                                       depth2d_array<float> shadowMap,
                                       float3 worldPos,
                                       float3 surfaceNormal) {
    if (shadow.strength <= 0.0) {
        return 1.0;
    }
    // Distance fade first: everything past the fade end is fully lit and
    // never touches a cascade.
    float distanceToEye = length(worldPos - shadow.eye);
    if (distanceToEye >= shadow.fadeEndDistance) {
        return 1.0;
    }
    float fade = 1.0 - smoothstep(shadow.fadeStartDistance, shadow.fadeEndDistance, distanceToEye);

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

    // A geometrically self-shadowed wall is lit by the sky, so it darkens to
    // only a fraction of the shadow strength; occluded spots the shadow map
    // finds (cast shadows) keep the full strength. The two components blend
    // smoothly across the N·L transition band.
    const float selfShadowStrengthFraction = 0.35;
    if (geometricVisibility <= 0.0) {
        // Fully self-shadowed: the exact value the general formula below
        // yields with no map term, without projecting a single cascade.
        return 1.0 - selfShadowStrengthFraction * shadow.strength * fade;
    }

    // Receivers without a normal are the ground plane.
    float3 gradientNormal = hasNormal > 0.0 ? normal : float3(0.0, 0.0, 1.0);
    float mapVisibility = 1.0;
    for (int i = 0; i < 3; ++i) {
        float3 position = worldPos + normal * shadow.cascades[i].normalOffsetWorld;
        float4 projected = shadow.cascades[i].worldToShadowTexture * float4(position, 1.0);
        float3 uvz = projected.xyz / projected.w;
        if (!shadowCascadeContains(shadow.cascades[i], uvz)) {
            continue;
        }
        float2 gradient = shadowAnalyticGradient(shadow.cascades[i], gradientNormal);
        float cascadeVisibility = shadowCascadeVisibility(shadow.cascades[i], shadowMap,
                                                          uint(i), uvz, gradient);
        // Cross-fade to the next cascade near this window's edge.
        // The cascade windows are anchored at the camera's look-at
        // point, so panning drives content through them: with a hard
        // containment switch the sharp-to-coarse texel boundary sweeps
        // across facades and reads as the shadow edge crawling along
        // the wall during fast movement. Blending over a few texels
        // turns that traveling seam into a gradual, invisible change.
        float2 uv = uvz.xy;
        float2 distanceToMin = uv - shadow.cascades[i].uvMinimum;
        float2 distanceToMax = shadow.cascades[i].uvMaximum - uv;
        float edgeDistance = min(min(distanceToMin.x, distanceToMin.y),
                                 min(distanceToMax.x, distanceToMax.y));
        float blendBand = 8.0 * max(shadow.cascades[i].texelSizeUV.x,
                                    shadow.cascades[i].texelSizeUV.y);
        if (i + 1 < 3 && edgeDistance < blendBand) {
            float3 nextPosition = worldPos + normal * shadow.cascades[i + 1].normalOffsetWorld;
            float4 nextProjected = shadow.cascades[i + 1].worldToShadowTexture * float4(nextPosition, 1.0);
            float3 nextUvz = nextProjected.xyz / nextProjected.w;
            if (shadowCascadeContains(shadow.cascades[i + 1], nextUvz)) {
                float2 nextGradient = shadowAnalyticGradient(shadow.cascades[i + 1], gradientNormal);
                float nextVisibility = shadowCascadeVisibility(shadow.cascades[i + 1], shadowMap,
                                                               uint(i + 1), nextUvz, nextGradient);
                cascadeVisibility = mix(nextVisibility, cascadeVisibility,
                                        saturate(edgeDistance / blendBand));
            }
        }
        mapVisibility = cascadeVisibility;
        break;
    }

    float selfShadowAmount = (1.0 - geometricVisibility) * selfShadowStrengthFraction;
    float castShadowAmount = geometricVisibility * (1.0 - mapVisibility);
    float shadowAmount = min(1.0, selfShadowAmount + castShadowAmount);
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
// HorizonFogUniform.swift. Two parts. The seam fog: distances measured in
// eye heights above the plane, so the band is geometrically glued to the
// vanishing line, saturating just below it to the frame's clear colour,
// which is what hides the coverage edge and the horizon-line seam of the
// surface switch. The haze: the globe atmosphere's profile turned inward,
// three exponentials of the pixel's angle below the horizon (a dense band
// hugging it, a wide faint glow down the plain, a whitening right at the
// line), in the halo's tint, so the far range dissolves into the same air
// the limb wore on the sphere and the sky above continues the profile
// upward (flatSkyFragmentShader). `hazeStrength` 0 keeps the seam fog alone
// (transparent space, where no sky is painted).
struct HorizonFog {
    float3 color;
    float3 eye;
    float strength;
    float startEyeHeights;
    float endEyeHeights;
    float hazeStrength;
    float3 hazeColor;
    float bandRadians;
    float glowRadians;
    float whitenRadians;
    float skyBandRadians;
};

constant float kHorizonHazeBandWeight = 0.85;
constant float kHorizonHazeGlowWeight = 0.22;
constant float kHorizonHazeWhitenWeight = 0.5;
// Below this angle under the horizon the haze is exactly zero (it fades
// out from the cutoff start): a downward view stays byte-clean, as the
// seam fog always kept it.
constant float kHorizonHazeCutoffStartRadians = 20.0 * M_PI_F / 180.0;
constant float kHorizonHazeCutoffEndRadians = 40.0 * M_PI_F / 180.0;

/// The haze colour at an angle below the horizon (radians, >= 0): the halo
/// tint, whitened toward the line.
static inline float3 horizonHazeTint(constant HorizonFog& fog, float belowRadians) {
    float whiten = exp(-belowRadians / fog.whitenRadians) * kHorizonHazeWhitenWeight;
    return mix(fog.hazeColor, float3(1.0), whiten);
}

/// How much haze covers the ground at an angle below the horizon.
static inline float horizonHazeAmount(constant HorizonFog& fog, float belowRadians) {
    float band = exp(-belowRadians / fog.bandRadians);
    float glow = exp(-belowRadians / fog.glowRadians);
    float cutoff = 1.0 - smoothstep(kHorizonHazeCutoffStartRadians, kHorizonHazeCutoffEndRadians, belowRadians);
    return saturate(band * kHorizonHazeBandWeight + glow * kHorizonHazeGlowWeight) * cutoff * fog.hazeStrength;
}

/// What a pixel below the horizon shows where nothing was drawn (a hole in
/// the coverage): the clear colour, hazed exactly as the ground there would
/// be, so the hole matches its surroundings from the camera's feet to the
/// line.
static inline float3 horizonHoleColor(constant HorizonFog& fog, float belowRadians) {
    return mix(fog.color, horizonHazeTint(fog, belowRadians), horizonHazeAmount(fog, belowRadians));
}

/// The sky colour at an angle above the horizon (radians, >= 0): the
/// horizon's whitened tint deepening to the halo blue upward, the profile
/// the ground haze continues across the line.
static inline float3 horizonSkyColor(constant HorizonFog& fog, float aboveRadians) {
    float3 lineTint = horizonHazeTint(fog, 0.0);
    return mix(lineTint, fog.hazeColor, 1.0 - exp(-aboveRadians / fog.skyBandRadians));
}

/// The fog's amount and target at a ground point: the seam fog by distance,
/// the haze by angle, whichever covers more, in the haze tint when the haze
/// is on and the clear colour otherwise.
static inline float2 horizonFogAmountAndTintWeight(constant HorizonFog& fog,
                                                   float3 worldPos,
                                                   thread float3& target) {
    float eyeHeight = max(abs(fog.eye.z), 1e-4);
    float3 toPoint = worldPos - fog.eye;
    float distanceToEye = length(toPoint);
    float seamFog = smoothstep(fog.startEyeHeights * eyeHeight,
                               fog.endEyeHeights * eyeHeight,
                               distanceToEye);
    float below = atan2(eyeHeight, max(length(toPoint.xy), 1e-6));
    float haze = horizonHazeAmount(fog, below);
    target = mix(fog.color, horizonHazeTint(fog, below), fog.hazeStrength);
    return float2(max(seamFog, haze) * fog.strength, 0.0);
}

static inline float3 applyHorizonFog(float3 color,
                                     constant HorizonFog& fog,
                                     float3 worldPos) {
    float3 target;
    float amount = horizonFogAmountAndTintWeight(fog, worldPos, target).x;
    return mix(color, target, amount);
}

// Half-precision fragment tails: the fog distances stay float (world units
// overflow half), only the final unit-range mix runs in half.
static inline half3 applyHorizonFog(half3 color,
                                    constant HorizonFog& fog,
                                    float3 worldPos) {
    float3 target;
    half amount = half(horizonFogAmountAndTintWeight(fog, worldPos, target).x);
    return mix(color, half3(target), amount);
}

#endif
