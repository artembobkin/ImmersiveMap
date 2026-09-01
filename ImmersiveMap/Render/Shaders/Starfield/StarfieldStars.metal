// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"
#include "../Shared/GeoMath.h"

// The stars around the globe. Space itself is not drawn here: the world
// pass's clear color paints it (already blended toward the flat map's color
// by the transition), and the stars blend additively over it.

struct StarVertexIn {
    float3 position [[attribute(0)]];
    float size [[attribute(1)]];
    float brightness [[attribute(2)]];
    float temperature [[attribute(3)]];
    float twinklePhase [[attribute(4)]];
    float halo [[attribute(5)]];
};

// Star attributes are unit-range (phase is 0..2pi), so the interpolants ride
// as half: cheaper interpolation and half-rate fragment math on A-series GPUs,
// identical rate on M-series.
struct StarVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    half brightness;
    half temperature;
    half twinklePhase;
    half halo;
    half transition;
};

struct StarfieldParams {
    /// The globe's pan rotation, row-vector layout (`v * M`), computed once
    /// per frame on the CPU.
    float4x4 rotation;
    float radiusScale;
    float3 padding;
};

vertex StarVertexOut starfieldVertexShader(StarVertexIn in [[stage_in]],
                                           constant Camera& camera [[buffer(1)]],
                                           constant Globe& globe [[buffer(2)]],
                                           constant StarfieldParams& params [[buffer(3)]]) {
    StarVertexOut out;
    float starRadius = globe.radius * params.radiusScale;
    float4 world = float4(in.position * starRadius, 1.0) * params.rotation * translationMatrix(float3(0, 0, -globe.radius));
    out.position = camera.matrix * world;
    // Stars are background: forced to the far plane so the sky depth test
    // rejects them wherever the globe surface has written depth.
    out.position.z = out.position.w;
    float sizeScale = starRadius / globe.radius;
    out.pointSize = max(1.2, in.size * sizeScale * 0.32);
    out.brightness = half(in.brightness);
    out.temperature = half(in.temperature);
    out.twinklePhase = half(in.twinklePhase);
    out.halo = half(in.halo);
    out.transition = half(globe.transition);
    return out;
}

fragment float4 starfieldFragmentShader(StarVertexOut in [[stage_in]],
                                        float2 pointCoord [[point_coord]],
                                        constant float &time [[buffer(0)]]) {
    half2 centered = half2(pointCoord) * 2.0h - 1.0h;
    half radiusSquared = dot(centered, centered);
    if (radiusSquared > 1.0h) {
        discard_fragment();
    }

    // All terms are unit-range, so the whole sprite evaluates in half. The
    // twinkle argument stays float: time grows unbounded and would lose the
    // phase entirely at half precision.
    half core = exp(-radiusSquared * 7.8h);
    half halo = exp(-radiusSquared * 2.35h) * (0.45h + in.halo * 0.95h);
    half crossGlow = exp(-abs(centered.x * centered.y) * 10.0h) * 0.08h * in.halo;
    half twinkle = 0.9h + 0.1h * half(sin(time * (1.0 + float(in.halo) * 1.3) + float(in.twinklePhase)));
    half intensity = in.brightness * twinkle;

    half3 warm = half3(1.0h, 0.88h, 0.78h);
    half3 neutral = half3(0.96h, 0.97h, 1.0h);
    half3 cool = half3(0.72h, 0.83h, 1.0h);
    half clampedTemperature = clamp(in.temperature, 0.0h, 1.0h);
    half3 color = clampedTemperature < 0.5h
        ? mix(warm, neutral, clampedTemperature * 2.0h)
        : mix(neutral, cool, (clampedTemperature - 0.5h) * 2.0h);

    half transitionAlpha = 1.0h - smoothstep(0.0h, 1.0h, in.transition);
    half alpha = saturate(core * 0.95h + halo * 0.55h + crossGlow) * intensity * transitionAlpha;
    half3 emissive = color * (core * 1.3h + halo * 0.75h + crossGlow * 1.6h) * intensity * transitionAlpha;
    return float4(float3(emissive), float(alpha));
}
