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

// Grazing-wall cutoff for the geometric self-shadow test, in N·L. Below the
// start the face is declared self-shadowed and never reaches the map: its
// depth changes by more than a texel across the receiver, which a constant
// bias cannot cover and the normal offset alone does not reach. The band is
// wider than a gradient-corrected sampler would need, which is the price of
// having no receiver-plane gradient. Mirrored by
// ShadowFrameStateResolver.geometricCutoff{Start,End}.
constant float kShadowGeometricCutoffStart = 0.18;
constant float kShadowGeometricCutoffEnd = 0.35;

// The single shadow window; the layout mirrors ShadowCascadeUniform.swift
// (pinned by ShadowUniformLayoutTests). worldToShadowTexture maps world space
// straight to the shadow map: xy = texture UV, z = the comparison depth.
struct ShadowCascade {
    float4x4 worldToShadowTexture;
    // Reserved (kept for layout stability).
    float2 kernelRadiusUV;
    float depthBias;
    float _padding1;
    // Valid UV rectangle, inset so the bilinear tap never leaves the window.
    float2 uvMinimum;
    float2 uvMaximum;
    // World-space normal-offset distance for receivers with normals
    // (normalOffsetTexels of this window, uncapped: the window is sized to
    // the camera distance, so the offset is a fixed fraction of it).
    float normalOffsetWorld;
    float _padding0;
    // One texel in UV; kept for the window-edge math.
    float2 texelSizeUV;
};

// Light matrix of the caster pass; the layout mirrors ShadowCasterUniform.swift
// (pinned by ShadowUniformLayoutTests). One window means one matrix and one
// draw per caster geometry.
struct ShadowCasterMatrices {
    float4x4 lightProjectionView;
};

// Directional shadow sampling parameters; the layout mirrors ShadowUniform.swift.
struct Shadow {
    ShadowCascade cascade;
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

static inline bool shadowWindowContains(constant ShadowCascade& cascade, float3 uvz) {
    return uvz.x >= cascade.uvMinimum.x && uvz.x <= cascade.uvMaximum.x &&
           uvz.y >= cascade.uvMinimum.y && uvz.y <= cascade.uvMaximum.y &&
           uvz.z >= 0.0 && uvz.z <= 1.0;
}

// One hardware-bilinear compare: a 2x2 PCF. Acne is prevented by moving the
// sample point off the receiver along its normal (see normalOffsetWorld) and
// by the constant depthBias, not by a receiver-plane gradient: nothing here
// reads a second texel or takes a derivative, so callers may branch freely
// around the call.
static inline float shadowWindowVisibility(constant ShadowCascade& cascade,
                                           depth2d<float> shadowMap,
                                           float3 uvz) {
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    mip_filter::none,
                                    address::clamp_to_edge,
                                    compare_func::less_equal);
    return shadowMap.sample_compare(shadowSampler, uvz.xy, uvz.z - cascade.depthBias);
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
//    definition (no map lookup is needed or trusted there), with a smoothstep
//    band at grazing angles where the wall's map footprint is sub-texel and
//    the stored depth cannot be trusted;
//  * normal-offset sampling: the sample point shifts off the surface along
//    the normal by normalOffsetTexels window texels, so a lit face cannot
//    stripe against its own quantized depth record, while occluders farther
//    away than the offset still shadow it.
//
// One window: a point outside it is lit by construction, and the eye-distance
// fade hides that edge. Derivative-free, so the early exits below are free to
// return before the projection: beyond the distance fade, or geometrically
// self-shadowed (a face fully turned from the sun).
static inline float sampleShadowFactor(constant Shadow& shadow,
                                       depth2d<float> shadowMap,
                                       float3 worldPos,
                                       float3 surfaceNormal) {
    if (shadow.strength <= 0.0) {
        return 1.0;
    }
    // Distance fade first: everything past the fade end is fully lit and
    // never touches the map.
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
    // Grazing walls are declared self-shadowed rather than sampled: their
    // depth varies by more than a texel across the receiver, which the
    // constant bias cannot cover and the normal offset alone does not reach.
    float geometricVisibility = hasNormal > 0.0
        ? smoothstep(kShadowGeometricCutoffStart, kShadowGeometricCutoffEnd,
                     dot(normal, shadow.lightDirection))
        : 1.0;

    // A geometrically self-shadowed wall is lit by the sky, so it darkens to
    // only a fraction of the shadow strength; occluded spots the shadow map
    // finds (cast shadows) keep the full strength. The two components blend
    // smoothly across the N·L transition band.
    const float selfShadowStrengthFraction = 0.35;
    if (geometricVisibility <= 0.0) {
        // Fully self-shadowed: the exact value the general formula below
        // yields with no map term, without projecting anything.
        return 1.0 - selfShadowStrengthFraction * shadow.strength * fade;
    }

    float3 position = worldPos + normal * shadow.cascade.normalOffsetWorld;
    // The light projection is orthographic, so w is 1 and no divide is needed.
    float3 uvz = (shadow.cascade.worldToShadowTexture * float4(position, 1.0)).xyz;
    float mapVisibility = shadowWindowContains(shadow.cascade, uvz)
        ? shadowWindowVisibility(shadow.cascade, shadowMap, uvz)
        : 1.0;

    float selfShadowAmount = (1.0 - geometricVisibility) * selfShadowStrengthFraction;
    float castShadowAmount = geometricVisibility * (1.0 - mapVisibility);
    float shadowAmount = min(1.0, selfShadowAmount + castShadowAmount);
    return 1.0 - shadowAmount * shadow.strength * fade;
}

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

#endif
