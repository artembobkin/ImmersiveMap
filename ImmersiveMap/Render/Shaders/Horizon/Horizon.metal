// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

// The horizon layer: the air around the surface's visible edge, resolved per
// pixel from the view ray. The edge is the limb of the sphere the surface
// currently lives on (the resting globe, or the growing sphere of the
// unroll) and, at zero curvature, the plane's horizon; the CPU hands the
// edge over as the eye's local vertical plus the limb's depression below
// it, so the fragment never touches the sphere's centre coordinate and the
// plane is not a special case (HorizonEdgeMath.swift mirrors the angle).
//
// One fragment function, two draws of the world pass right after the last
// world layer, split by the depth buffer: the sky side runs under the
// far-plane lessEqual test and reaches only pixels nothing painted (space,
// coverage holes, the polar caps, which write no depth), the ground side
// under a far-plane greater test and reaches only painted pixels, with its
// angle clamped to the edge so the whitening lands on the rasterized limb.
// Each pixel is shaded once. Pure arithmetic, no texture reads, no discard.
//
// Three things share the profile (HorizonFrameResolver.swift decides their
// strengths per frame): the globe's atmosphere (the band and glow outside
// the limb, the rim inside, the whitening at it), the limb feather (a glow
// a couple of pixels wide across the edge that hides the tile mesh's chord
// polygon and the silhouette's staircase) and the flat map's fog band (the
// ground side alone, saturating to the fog colour at the horizon line).
//
// Layout mirrors HorizonUniform.swift (pinned by HorizonUniformLayoutTests).
struct Horizon {
    float4x4 inverseViewProjection;
    float3 up;
    float depression;
    float3 center;
    float sunInfluence;
    float3 light;
    float skyStrength;
    float3 tint;
    float whitenWeight;
    float3 eye;
    float featherStrength;
    float bandRadians;
    float glowRadians;
    float whitenRadians;
    float featherRadians;
    float groundBandRadians;
    float groundGain;
    float cutoffStartRadians;
    float cutoffEndRadians;
};

/// True for the ground-side draw: the angle is clamped to the edge, so a
/// painted pixel the analytic edge would put in the sky (the limb pixel
/// itself, under float noise) takes the edge's own value.
constant bool kHorizonGroundSide [[function_constant(0)]];

// The sky side's profile, weights of the band hugging the edge and of the
// wide glow away from it. Mirrored by HorizonFrameResolverTests through the
// shader source.
constant float kHorizonBandWeight = 0.85;
constant float kHorizonGlowWeight = 0.22;

struct HorizonVertexOut {
    float4 position [[position]];
    float2 ndc;
};

vertex HorizonVertexOut horizonVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    HorizonVertexOut out;
    // At the far plane: the two depth tests of the layer compare against
    // the cleared depth (sky side) and against everything nearer (ground).
    out.position = float4(positions[vertexID], 1.0, 1.0);
    out.ndc = positions[vertexID];
    return out;
}

/// Signed angle of a unit view direction above the edge: its elevation over
/// the eye's local horizontal plus the limb's depression. Mirrored by
/// HorizonEdgeMath.angleAboveEdge.
static inline float horizonAngleAboveEdge(constant Horizon& horizon, float3 direction) {
    return asin(clamp(dot(direction, horizon.up), -1.0, 1.0)) + horizon.depression;
}

/// The atmosphere outside the edge: a bright band hugging the limb (the
/// dense air) and a wide faint glow into space (the thin air).
static inline float horizonSkyProfile(constant Horizon& horizon, float aboveRadians) {
    float band = exp(-aboveRadians / horizon.bandRadians);
    float glow = exp(-aboveRadians / horizon.glowRadians);
    return saturate(band * kHorizonBandWeight + glow * kHorizonGlowWeight);
}

/// The haze over the surface below the edge: one exponential with a gain
/// (above one it saturates at the line, which is the fog band), cut off
/// smoothly so the map under the camera stays byte-clean. Mirrored by
/// HorizonFrameResolver.groundProfile.
static inline float horizonGroundProfile(constant Horizon& horizon, float belowRadians) {
    float amount = saturate(exp(-belowRadians / horizon.groundBandRadians) * horizon.groundGain);
    float cutoff = 1.0 - smoothstep(horizon.cutoffStartRadians, horizon.cutoffEndRadians, belowRadians);
    return amount * cutoff;
}

/// The sun's side of the limb: the halo is full where the limb normal faces
/// the scene light and dims to a residual glow opposite it, by the frame's
/// sun influence (zero on the plane and with the atmosphere off).
static inline float horizonSunFactor(constant Horizon& horizon, float3 direction) {
    if (horizon.sunInfluence <= 0.0) {
        return 1.0;
    }
    float3 toCenter = horizon.center - horizon.eye;
    float3 nearest = horizon.eye + direction * max(dot(toCenter, direction), 0.0);
    float3 normal = normalize(nearest - horizon.center);
    float day = smoothstep(-0.25, 0.25, dot(normal, horizon.light));
    return 1.0 - horizon.sunInfluence * (1.0 - day);
}

fragment half4 horizonFragmentShader(HorizonVertexOut in [[stage_in]],
                                     constant Horizon& horizon [[buffer(0)]]) {
    float4 farPoint = horizon.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 direction = normalize(farPoint.xyz / farPoint.w - horizon.eye);
    float above = horizonAngleAboveEdge(horizon, direction);
    if (kHorizonGroundSide) {
        above = min(above, 0.0);
    }

    float haze;
    if (above >= 0.0) {
        haze = horizonSkyProfile(horizon, above) * horizon.skyStrength * horizonSunFactor(horizon, direction);
    } else {
        haze = horizonGroundProfile(horizon, -above);
    }
    float distanceToEdge = abs(above);
    float feather = exp(-distanceToEdge / horizon.featherRadians) * horizon.featherStrength;
    float whiten = exp(-distanceToEdge / horizon.whitenRadians) * horizon.whitenWeight;

    // Premultiplied output over what is behind: the tint, whitened toward
    // the edge, weighted by the coverage; the coverage in alpha, so the air
    // covers the edge and thins to nothing both into space and over the map.
    float coverage = saturate(haze + feather * (1.0 - haze));
    float3 color = mix(horizon.tint, float3(1.0), whiten);
    return half4(half3(color * coverage), half(coverage));
}
