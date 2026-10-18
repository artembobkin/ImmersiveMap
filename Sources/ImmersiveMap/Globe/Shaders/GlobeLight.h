// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeLight.h
//  ImmersiveMap
//
//  The sun on the globe (GlobeLightSettings): the surface shaded by the
//  sphere's normal against the scene light, the day side as the style
//  paints it, the night side drawn toward the night colour, a soft
//  terminator between. Every fragment stage of the globe's surface (the
//  tiles' fills and lines, the raster rings, the polar caps) multiplies its
//  colour through globeLitColor, from fragment buffer kGlobeLightBufferIndex.
//  The light is the scene light as a world direction, the one the
//  atmosphere's halo reads (Horizon.metal), so the halo and the ground
//  agree on where the day is.
//

#include <metal_stdlib>
using namespace metal;

#ifndef GLOBE_LIGHT
#define GLOBE_LIGHT

/// Mirror of GlobeLightUniform.swift.
struct GlobeLight {
    /// The direction toward the sun in world space, unit length, and how
    /// much of the shading the surface takes this frame (0 none: the
    /// surface keeps its colour and nothing is read).
    float4 lightAndStrength;
    /// The colour the night side is drawn toward and the terminator's
    /// softness in the cosine of the sun's angle to the normal.
    float4 nightColorAndSoftness;
};

/// The fragment buffer every lit globe shader reads the light from: past
/// the slots those shaders bind of their own.
#define kGlobeLightBufferIndex 9

/// A surface colour under the globe's light at a point whose sphere normal
/// (world space, unit length) is `normal`: the colour itself where the
/// normal faces the sun, toward the night colour where it faces away, a
/// smoothstep across the terminator, all of it scaled by the strength.
static inline half3 globeLitColor(half3 color, float3 normal, constant GlobeLight& light) {
    float strength = light.lightAndStrength.w;
    if (strength <= 0.0) {
        return color;
    }
    float softness = max(light.nightColorAndSoftness.w, 1e-3);
    float day = smoothstep(-softness, softness, dot(normalize(normal), light.lightAndStrength.xyz));
    half3 night = half3(light.nightColorAndSoftness.rgb);
    return mix(color, night, half(strength * (1.0 - day)));
}

#endif
