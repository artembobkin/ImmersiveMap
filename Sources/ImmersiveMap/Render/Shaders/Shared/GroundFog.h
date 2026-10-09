// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GroundFog.h
//  ImmersiveMap
//
//  The fog on the ground of the flat map (GroundFogSettings): thickest at
//  the ground, its density falling by a factor of e every `height` upward,
//  gathered along the view ray past `startDistance` from the camera and
//  coming in smoothly over `startSoftness` past it. Every shader of what
//  stands on the map (the ground, the roads, the labels painted on it, the
//  buildings, the models) mixes its colour toward the fog's by
//  groundFogAmount, from fragment buffer kGroundFogBufferIndex. The fog's
//  colour is the sky's in the direction of the view (groundFogColor), so a
//  far building veiled in full is the sky behind it, not a pale block on it.
//  Every length is in meters on the ground: the render world's units are
//  turned into meters by the uniform's factor, so a fog layer 60 m high is
//  60 m high at every zoom.
//

#include <metal_stdlib>
using namespace metal;

#ifndef GROUND_FOG
#define GROUND_FOG

/// Mirror of GroundFogUniform.swift.
struct GroundFog {
    /// The fog's colour at the horizon line and its density at the ground,
    /// per meter.
    float4 colorAndDensity;
    /// The eye in render world units and the meters one unit spans.
    float4 eyeAndMetersPerUnit;
    /// The height its density falls by e over and the distance it begins
    /// at, both in meters, the most it veils, and its strength (0 with the
    /// fog off and on the globe).
    float4 parameters;
    /// The sky's colour away from the line and the e-fold, in radians above
    /// the line, of the horizon's glow it decays out of (0 with no sky
    /// painted: the fog keeps its colour).
    float4 skyColorAndGradient;
    /// The distance, in meters, the fog's density takes to come in past its
    /// start. The rest is padding.
    float4 startSoftness;
};

/// The fragment buffer every fogged shader reads the fog from: past every
/// slot those shaders bind of their own.
#define kGroundFogBufferIndex 12

/// How much of the fog lies between the eye and a point, 0 to 1: one minus
/// the light that crosses it, the density's integral along the ray from the
/// start distance to the point. Along the ray the height is linear, so the
/// integral of e^(-z/H) is exact: the span times the mean of the exponent
/// at its two ends' heights. Past the start the density comes in on a
/// smoothstep over the softness, whose integral is exact too: the span
/// weighs `w (t^3 - t^4 / 2)` of its length at `t` softnesses in, and its
/// length less half the softness past it. So the veil starts with no edge.
static inline float groundFogAmount(float3 worldPosition, constant GroundFog& fog) {
    float strength = fog.parameters.w;
    if (strength <= 0.0) {
        return 0.0;
    }
    float metersPerUnit = fog.eyeAndMetersPerUnit.w;
    float3 eye = fog.eyeAndMetersPerUnit.xyz * metersPerUnit;
    float3 ray = worldPosition * metersPerUnit - eye;
    float rayLength = length(ray);
    float start = fog.parameters.y;
    if (rayLength <= start) {
        return 0.0;
    }
    float height = max(fog.parameters.x, 1e-3);
    float z0 = max(eye.z + ray.z * (start / rayLength), 0.0);
    float z1 = max(eye.z + ray.z, 0.0);
    float rise = (z1 - z0) / height;
    float e0 = exp(-z0 / height);
    float meanDensity = abs(rise) > 1e-4 ? (e0 - exp(-z1 / height)) / rise : e0;
    float span = rayLength - start;
    float softness = fog.startSoftness.x;
    float weightedSpan = span;
    if (softness > 0.0) {
        float t = span / softness;
        weightedSpan = t < 1.0 ? softness * (t * t * t - 0.5 * t * t * t * t) : span - 0.5 * softness;
    }
    float opticalDepth = fog.colorAndDensity.w * weightedSpan * meanDensity;
    return min(1.0 - exp(-opticalDepth), fog.parameters.z) * strength;
}

/// The fog's colour in the direction of a point: the sky the horizon layer
/// paints there (Horizon.metal), the fog's own colour at and under the line
/// decaying into the sky colour above it. A point veiled in full is then
/// the sky behind it. Mirrored by GroundFogUniform.color(elevation:).
static inline float3 groundFogColor(float3 worldPosition, constant GroundFog& fog) {
    float3 base = fog.colorAndDensity.rgb;
    float gradient = fog.skyColorAndGradient.w;
    if (gradient <= 0.0) {
        return base;
    }
    float3 ray = worldPosition - fog.eyeAndMetersPerUnit.xyz;
    float rayLength = length(ray);
    if (rayLength <= 0.0) {
        return base;
    }
    // On the plane the line is the eye's horizontal, so the angle above it
    // is the ray's elevation.
    float elevation = asin(clamp(ray.z / rayLength, -1.0, 1.0));
    if (elevation <= 0.0) {
        return base;
    }
    return mix(base, fog.skyColorAndGradient.rgb, 1.0 - exp(-elevation / gradient));
}

static inline half3 applyGroundFog(half3 color, float3 worldPosition, constant GroundFog& fog) {
    float amount = groundFogAmount(worldPosition, fog);
    if (amount <= 0.0) {
        return color;
    }
    return mix(color, half3(groundFogColor(worldPosition, fog)), half(amount));
}

#endif
