// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"

// The atmosphere halo: the scattered light around the planet's edge, painted
// in space just outside the sphere. Drawn as one fullscreen triangle between
// the starfield and the globe surface, with depth off; the surface then covers
// the part of the halo that lies inside the silhouette.
//
// Layout mirrors AtmosphereUniform.swift (pinned by AtmosphereUniformLayoutTests).
struct Atmosphere {
    float4x4 inverseViewProjection;
    float3 eye;
    float3 center;
    float3 color;
    float3 sunDirection;
    float radius;
    float transition;
    float intensity;
    float thickness;
    float sunInfluence;
    float _padding0;
    float _padding1;
    float _padding2;
};

struct AtmosphereVertexOut {
    float4 position [[position]];
    float2 ndc;
};

vertex AtmosphereVertexOut atmosphereVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    AtmosphereVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.ndc = positions[vertexID];
    return out;
}

// The falloff profile, in globe radii outside the silhouette. Three terms,
// each an exponential of the distance past the limb, because that is what a
// thin shell of gas lit from behind the horizon looks like from space: a
// bright band hugging the limb (the dense air), a wide faint glow into space
// (the thin air), and a whitening right at the edge where the scattering
// saturates. Their widths scale with `thickness`, so the whole profile
// stretches or tightens as one shape.
constant float kAtmosphereBandWidth = 0.075;
constant float kAtmosphereGlowWidth = 0.34;
constant float kAtmosphereWhitenWidth = 0.018;
constant half kAtmosphereBandWeight = 0.85h;
constant half kAtmosphereGlowWeight = 0.22h;
constant half kAtmosphereWhitenWeight = 0.5h;
// The halo is gone by the time the sphere is a third unrolled, the same
// window the polar cap fades in: past it the limb the halo is fitted to has
// started moving.
constant half kAtmosphereTransitionFadeEnd = 0.35h;
// The night side keeps this fraction of the halo at full sun influence: a
// planet's air still glows a little in the dark, and a hard cut at the
// terminator would read as a broken ring.
constant half kAtmosphereNightFloor = 0.28h;

fragment half4 atmosphereFragmentShader(AtmosphereVertexOut in [[stage_in]],
                                        constant Atmosphere& atmosphere [[buffer(0)]]) {
    // The view ray through this pixel: unproject the far-plane point and aim
    // at it from the eye. Exact for any camera the map can take, including a
    // globe pushed off center or tilted, where the silhouette is no circle.
    float4 farPoint = atmosphere.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 direction = normalize(farPoint.xyz / farPoint.w - atmosphere.eye);
    float3 toEye = atmosphere.eye - atmosphere.center;
    float along = dot(toEye, direction);
    // Closest approach of the ray to the sphere center. A positive `along`
    // puts it behind the eye: the pixel looks away from the planet, and the
    // eye itself is always outside the halo, so there is nothing to paint.
    if (along > 0.0) {
        return half4(0.0h);
    }
    float radius = max(atmosphere.radius, 1e-6);
    float perpendicular = sqrt(max(dot(toEye, toEye) - along * along, 0.0));
    // Distance past the limb in radii, held at zero inside the silhouette:
    // the halo runs at full brightness under the sphere edge, so the samples
    // of a partially covered limb pixel that the surface leaves unpainted
    // show halo rather than space, and the edge never gets a dark rim.
    float miss = max((perpendicular - radius) / radius, 0.0);
    float thickness = max(atmosphere.thickness, 0.05);

    half band = half(exp(-miss / (kAtmosphereBandWidth * thickness)));
    half glow = half(exp(-miss / (kAtmosphereGlowWidth * thickness)));
    half whiten = half(exp(-miss / (kAtmosphereWhitenWidth * thickness)));
    half brightness = band * kAtmosphereBandWeight + glow * kAtmosphereGlowWeight;

    half intensity = half(atmosphere.intensity);
    half fade = 1.0h - smoothstep(0.0h, kAtmosphereTransitionFadeEnd, half(atmosphere.transition));
    // With a sun, the halo follows the day side: the closest-approach point is
    // where this pixel's air sits, and its exposure to the sun decides how
    // much of the halo is lit. Without one the halo is even all around.
    if (atmosphere.sunInfluence > 0.0 && dot(atmosphere.sunDirection, atmosphere.sunDirection) > 0.5) {
        float3 airPoint = atmosphere.eye + direction * (-along);
        float3 airNormal = normalize(airPoint - atmosphere.center);
        float exposure = dot(airNormal, atmosphere.sunDirection);
        half daylight = half(smoothstep(-0.30, 0.25, exposure));
        half sunFactor = mix(1.0h, mix(kAtmosphereNightFloor, 1.0h, daylight), half(atmosphere.sunInfluence));
        intensity *= sunFactor;
    }

    // Premultiplied output over the space behind: the color is the halo tint,
    // whitened toward the limb, weighted by the brightness; the alpha is the
    // brightness itself, so the halo covers space at the limb and thins to
    // nothing with distance, and stars right behind the air dim under it.
    half3 tint = mix(half3(atmosphere.color), half3(1.0h), whiten * kAtmosphereWhitenWeight);
    half coverage = brightness * intensity * fade;
    return half4(tint * coverage, saturate(coverage));
}
