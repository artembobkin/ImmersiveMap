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

// The slices of the shadow map, one per window; mirrored by
// ShadowCascadeSlot.swift.
constant uint kShadowNearSlice = 0;
constant uint kShadowFarSlice = 1;

// One shadow window; the layout mirrors ShadowCascadeUniform.swift
// (pinned by ShadowUniformLayoutTests). worldToShadowTexture maps world space
// straight to the window's slice: xy = texture UV, z = the comparison depth.
struct ShadowCascade {
    float4x4 worldToShadowTexture;
    // Softness: the factor the tent's taps are pushed out by, about the
    // sample point. 1 is the plain 3x3 tent; higher lengthens the ramp
    // without moving the edge (see shadowWindowVisibility).
    float tentSpread;
    // Where the window's shadows start to fade and where they are gone, as
    // radial distances from Shadow.fadeCenter: the outer quarter of its
    // disc. The near window's band is where the far window takes over, the
    // far window's (the near one's alone without it) where shadows end.
    float fadeStartDistance;
    float depthBias;
    float fadeEndDistance;
    // Valid UV rectangle, inset so the tent's taps never leave the window,
    // at the widest spread the softness allows.
    float2 uvMinimum;
    float2 uvMaximum;
    // World-space normal-offset distance for receivers with normals
    // (normalOffsetTexels of this window, uncapped: the window is sized to
    // the camera distance, so the offset is a fixed fraction of it).
    float normalOffsetWorld;
    float _padding0;
    // One texel in UV: the tent's offsets and the window-edge math.
    float2 texelSizeUV;
};

// Light matrix of a caster pass; the layout mirrors ShadowCasterUniform.swift
// (pinned by ShadowUniformLayoutTests). Each window's pass binds its own
// matrix, so a caster geometry renders with one draw per window.
struct ShadowCasterMatrices {
    float4x4 lightProjectionView;
};

// Directional shadow sampling parameters; the layout mirrors ShadowUniform.swift.
struct Shadow {
    // The near window, sharp, around the ground the camera looks at, and the
    // far window, coarse, for the ground beyond it. A far window the frame
    // has not got is disabled: an empty UV rectangle (shadowCascadeIsEnabled).
    ShadowCascade near;
    ShadowCascade far;
    float3 eye;
    float strength;
    float _padding0;
    float _padding1;
    float _padding2;
    // Normalized direction towards the static sun, for the geometric
    // self-shadow test of receivers that have normals.
    float3 lightDirection;
    // RGB cast of a fully shadowed surface on top of the strength darkening:
    // white keeps the neutral darkening, a bluish tint gives shadows the cool
    // cast of light coming only from the sky.
    float3 tint;
    // Centre of the windows in world XY: what every fade distance is
    // measured from. It is the camera's ground point, the centre of the
    // circle each visible footprint is clamped to, so a fade band always lies
    // inside its fitted window whatever the coverage.
    float2 fadeCenter;
    float2 _padding3;
};

static inline bool shadowCascadeIsEnabled(constant ShadowCascade& cascade) {
    return cascade.uvMaximum.x >= cascade.uvMinimum.x;
}

// Which window a point reads and how far its shadows have faded there.
struct ShadowCascadeBlend {
    // 1 inside the near window, 0 past its fade band: the share of the near
    // window in the map's visibility, the rest is the far window's.
    float nearWeight;
    // 1 at full shadow strength, 0 where the shadows have ended: the far
    // window's fade, or the near window's when the frame has no far window.
    float fade;
    bool hasFar;
};

static inline ShadowCascadeBlend shadowCascadeBlend(constant Shadow& shadow, float2 worldXY) {
    float distanceToCenter = length(worldXY - shadow.fadeCenter);
    ShadowCascadeBlend blend;
    blend.hasFar = shadowCascadeIsEnabled(shadow.far);
    blend.nearWeight = 1.0 - smoothstep(shadow.near.fadeStartDistance, shadow.near.fadeEndDistance, distanceToCenter);
    blend.fade = blend.hasFar
        ? 1.0 - smoothstep(shadow.far.fadeStartDistance, shadow.far.fadeEndDistance, distanceToCenter)
        : blend.nearWeight;
    return blend;
}

static inline bool shadowWindowContains(constant ShadowCascade& cascade, float3 uvz) {
    return uvz.x >= cascade.uvMinimum.x && uvz.x <= cascade.uvMaximum.x &&
           uvz.y >= cascade.uvMinimum.y && uvz.y <= cascade.uvMaximum.y &&
           uvz.z >= 0.0 && uvz.z <= 1.0;
}

// Castaño's 3x3 tent PCF (The Witness): four hardware bilinear compares with
// computed weights reconstruct a C1 tent kernel.
//
// A single bilinear compare is exact along the shadow grid's own axes and
// staircases on every other angle, because a diagonal boundary has to be
// reconstructed from a square lattice. That is not a matter of the lattice
// being coarse: the steps shrink with the texel and never go away. It shows
// up as shadows whose edges are clean on the buildings that happen to stand
// along the sun and jagged on the ones that do not, changing as the sun
// turns, which is worse to look at than a uniformly soft edge.
//
// The tent gives the same ~2-texel ramp in EVERY orientation, so the edge
// stops carrying the grid's signature. Every receiver reads through here, the
// ground mask included, so there is one kernel in the frame rather than a
// smooth ground next to a stepped wall.
//
// `tentSpread` lengthens that ramp: the four taps are pushed away from the
// sample point, which costs nothing (the same four compares) and cannot move
// the shadow's edge, because a symmetric kernel puts the 50% contour on the
// true boundary whatever its width. What it does not do is remove the
// staircase at shallow angles to the grid: the steps are one texel of the
// map, and a wider kernel only rounds their corners. Softening is what this
// knob is for; sharpening is what a finer texel is for.
//
// Every tap compares against the same reference: acne is prevented by moving
// the sample point off the receiver along its normal (see normalOffsetWorld)
// and by the constant depthBias, not by a receiver-plane gradient, so no tap
// needs a per-tap depth prediction. Nothing here takes a derivative, so
// callers may branch freely around the call.
static inline float shadowWindowVisibility(constant ShadowCascade& cascade,
                                           depth2d_array<float> shadowMap,
                                           uint slice,
                                           float3 uvz) {
    constexpr sampler shadowSampler(coord::normalized,
                                    filter::linear,
                                    mip_filter::none,
                                    address::clamp_to_edge,
                                    compare_func::less_equal);
    float reference = uvz.z - cascade.depthBias;

    // Tent weights and offsets in texel space; conversions go through
    // texelSizeUV. The four taps land inside the window's sampling rectangle
    // because it is inset by `uvInsetTexels`, which is wider than this reach.
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

    // Softness. The weighted mean of the tap offsets is the sample point
    // itself (uw0*u0 + uw1*u1 = 4s exactly, and the weights sum to 4), so
    // scaling the offsets about it widens the kernel while leaving it
    // symmetric about the same point: the ramp gets longer, its centre stays.
    // The weights are untouched, so the taps drift off the positions that
    // reconstruct an exact tent; up to the clamped maximum the lobes that
    // opens are far below what the ramp itself is doing.
    float spread = cascade.tentSpread;
    u0 = s + (u0 - s) * spread;
    u1 = s + (u1 - s) * spread;
    v0 = t + (v0 - t) * spread;
    v1 = t + (v1 - t) * spread;

    float visibility = 0.0;
    visibility += uw0 * vw0 * shadowMap.sample_compare(shadowSampler,
                                                       baseUV + float2(u0, v0) * cascade.texelSizeUV,
                                                       slice,
                                                       reference);
    visibility += uw1 * vw0 * shadowMap.sample_compare(shadowSampler,
                                                       baseUV + float2(u1, v0) * cascade.texelSizeUV,
                                                       slice,
                                                       reference);
    visibility += uw0 * vw1 * shadowMap.sample_compare(shadowSampler,
                                                       baseUV + float2(u0, v1) * cascade.texelSizeUV,
                                                       slice,
                                                       reference);
    visibility += uw1 * vw1 * shadowMap.sample_compare(shadowSampler,
                                                       baseUV + float2(u1, v1) * cascade.texelSizeUV,
                                                       slice,
                                                       reference);
    return visibility * (1.0 / 16.0);
}

// One window's visibility at a point: the receiver stepped off its surface
// by the window's normal offset (`normal` zero for the ground), projected
// into the window's slice, lit outside its sampling rectangle.
static inline float shadowCascadeVisibility(constant ShadowCascade& cascade,
                                            depth2d_array<float> shadowMap,
                                            uint slice,
                                            float3 worldPos,
                                            float3 normal) {
    float3 position = worldPos + normal * cascade.normalOffsetWorld;
    // The light projection is orthographic, so w is 1 and no divide is needed.
    float3 uvz = (cascade.worldToShadowTexture * float4(position, 1.0)).xyz;
    return shadowWindowContains(cascade, uvz)
        ? shadowWindowVisibility(cascade, shadowMap, slice, uvz)
        : 1.0;
}

// The map's visibility at a point, 1 = fully lit: the near window where it
// reaches, the far window beyond it, the two blended over the near window's
// fade band, where a point costs both lookups. Without a far window the near
// window alone, and the band is then the fade of the shadows themselves
// (`blend.fade`), applied by the caller.
static inline float shadowMapVisibility(constant Shadow& shadow,
                                        depth2d_array<float> shadowMap,
                                        float3 worldPos,
                                        float3 normal,
                                        ShadowCascadeBlend blend) {
    float nearVisibility = 1.0;
    if (blend.nearWeight > 0.0) {
        nearVisibility = shadowCascadeVisibility(shadow.near, shadowMap, kShadowNearSlice, worldPos, normal);
    }
    if (!blend.hasFar) {
        return nearVisibility;
    }
    float farVisibility = 1.0;
    if (blend.nearWeight < 1.0) {
        farVisibility = shadowCascadeVisibility(shadow.far, shadowMap, kShadowFarSlice, worldPos, normal);
    }
    return mix(farVisibility, nearVisibility, blend.nearWeight);
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
// Two windows: a point outside both is lit by construction, and the last
// window's eye-distance fade hides that edge (shadowMapVisibility).
// Derivative-free, so the early exits below are free to return before the
// projection: beyond the distance fade, or geometrically self-shadowed (a
// face fully turned from the sun).
static inline float sampleShadowFactor(constant Shadow& shadow,
                                       depth2d_array<float> shadowMap,
                                       float3 worldPos,
                                       float3 surfaceNormal) {
    if (shadow.strength <= 0.0) {
        return 1.0;
    }
    // Distance fade first: everything past the last window's fade end is
    // fully lit and never touches the map. Measured radially from the
    // windows' centre, the same thing they are fitted around, so a band is
    // inside its window by construction and no pose of the camera moves it.
    ShadowCascadeBlend blend = shadowCascadeBlend(shadow, worldPos.xy);
    if (blend.fade <= 0.0) {
        return 1.0;
    }
    float fade = blend.fade;

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

    float mapVisibility = shadowMapVisibility(shadow, shadowMap, worldPos, normal, blend);

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
