// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GroundFog.h
//  ImmersiveMap
//
//  The fog on the ground of the flat map (GroundFogSettings): thickest at
//  the ground, its density falling by a factor of e every `height` upward,
//  gathered along the view ray past `startDistance` from the camera. Every
//  shader of what stands on the map (the ground, the roads, the labels
//  painted on it, the buildings, the models) mixes its colour toward the
//  fog's by groundFogAmount, from fragment buffer kGroundFogBufferIndex.
//  The lengths are camera distances, the distance from the eye to the
//  point it looks at, which is the render world's origin on the plane.
//

#include <metal_stdlib>
using namespace metal;

#ifndef GROUND_FOG
#define GROUND_FOG

/// Mirror of GroundFogUniform.swift.
struct GroundFog {
    /// The fog's colour and its density at the ground, per camera distance.
    float4 colorAndDensity;
    /// The eye in render world units and one over the camera distance.
    float4 eyeAndInverseDistance;
    /// The height its density falls by e over and the distance it begins
    /// at, both in camera distances, the most it veils, and its strength
    /// (0 with the fog off and on the globe).
    float4 parameters;
};

/// The fragment buffer every fogged shader reads the fog from: past every
/// slot those shaders bind of their own.
#define kGroundFogBufferIndex 12

/// How much of the fog lies between the eye and a point, 0 to 1: one minus
/// the light that crosses it, the density's integral along the ray from the
/// start distance to the point. Along the ray the height is linear, so the
/// integral of e^(-z/H) is exact: the span times the mean of the exponent
/// at its two ends' heights.
static inline float groundFogAmount(float3 worldPosition, constant GroundFog& fog) {
    float strength = fog.parameters.w;
    if (strength <= 0.0) {
        return 0.0;
    }
    float inverseDistance = fog.eyeAndInverseDistance.w;
    float3 eye = fog.eyeAndInverseDistance.xyz * inverseDistance;
    float3 ray = worldPosition * inverseDistance - eye;
    float rayLength = length(ray);
    float start = fog.parameters.y;
    if (rayLength <= start) {
        return 0.0;
    }
    float height = max(fog.parameters.x, 1e-4);
    float z0 = max(eye.z + ray.z * (start / rayLength), 0.0);
    float z1 = max(eye.z + ray.z, 0.0);
    float rise = (z1 - z0) / height;
    float e0 = exp(-z0 / height);
    float meanDensity = abs(rise) > 1e-4 ? (e0 - exp(-z1 / height)) / rise : e0;
    float opticalDepth = fog.colorAndDensity.w * (rayLength - start) * meanDensity;
    return min(1.0 - exp(-opticalDepth), fog.parameters.z) * strength;
}

static inline half3 applyGroundFog(half3 color, float3 worldPosition, constant GroundFog& fog) {
    float amount = groundFogAmount(worldPosition, fog);
    return amount > 0.0 ? mix(color, half3(fog.colorAndDensity.rgb), half(amount)) : color;
}

#endif
