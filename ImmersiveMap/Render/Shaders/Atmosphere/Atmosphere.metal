// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

// The atmosphere: the scattered light around the planet's limb, resolved per
// pixel from the view ray and the sphere (under perspective the silhouette
// is a conic, so a screen-space circle would detach from the limb on a
// tilted view). One fullscreen triangle in the world pass right after the
// globe surface and the polar caps, blending premultiplied over the frame;
// pure arithmetic, no texture reads. Nothing on the sphere writes depth the
// pass could test against, so the inside of the silhouette is shaped
// analytically instead: the same profile that falls off into space decays
// inward as a narrow rim glow over the surface, continuous across the limb,
// which also hides the geometric edge of the tile mesh.
//
// Layout mirrors AtmosphereUniform.swift (pinned by AtmosphereUniformLayoutTests).
struct Atmosphere {
    float4x4 inverseViewProjection;
    float3 eye;
    float3 center;
    float3 color;
    float radius;
    float transition;
    float intensity;
    float thickness;
};

struct AtmosphereVertexOut {
    float4 position [[position]];
    float2 ndc;
};

vertex AtmosphereVertexOut atmosphereVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    AtmosphereVertexOut out;
    out.position = float4(positions[vertexID], 1.0, 1.0);
    out.ndc = positions[vertexID];
    return out;
}

// The falloff profile, in globe radii around the silhouette. Outside the
// limb, three exponentials of the distance past it, because that is what a
// thin shell of gas looks like from space: a bright band hugging the limb
// (the dense air), a wide faint glow into space (the thin air), and a
// whitening right at the edge where the scattering saturates. Inside the
// limb the whole profile decays as one narrow rim over the surface. The
// widths scale with `thickness`, so the profile stretches as one shape.
constant float kAtmosphereBandWidth = 0.075;
constant float kAtmosphereGlowWidth = 0.34;
constant float kAtmosphereWhitenWidth = 0.018;
constant float kAtmosphereRimWidth = 0.025;
constant half kAtmosphereBandWeight = 0.85h;
constant half kAtmosphereGlowWeight = 0.22h;
constant half kAtmosphereWhitenWeight = 0.5h;
// The halo is gone by the time the sphere is a third unrolled, the same
// window the polar caps fade in: past it the limb the halo is fitted to has
// started moving.
constant half kAtmosphereTransitionFadeEnd = 0.35h;

fragment half4 atmosphereFragmentShader(AtmosphereVertexOut in [[stage_in]],
                                        constant Atmosphere& atmosphere [[buffer(0)]]) {
    // The view ray through this pixel: unproject the far-plane point and aim
    // at it from the eye.
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
    // Signed distance from the limb in radii: positive outside, negative
    // over the surface.
    float signedMiss = (perpendicular - radius) / radius;
    float thickness = max(atmosphere.thickness, 0.05);

    float miss = max(signedMiss, 0.0);
    half band = half(exp(-miss / (kAtmosphereBandWidth * thickness)));
    half glow = half(exp(-miss / (kAtmosphereGlowWidth * thickness)));
    half whiten = half(exp(-miss / (kAtmosphereWhitenWidth * thickness)));
    half brightness = band * kAtmosphereBandWeight + glow * kAtmosphereGlowWeight;
    // The rim: inside the silhouette the profile decays inward from full
    // strength at the limb, continuous across it, so the limb pixel itself
    // is always covered by air and never shows a hard geometric edge.
    if (signedMiss < 0.0) {
        brightness *= half(exp(signedMiss / (kAtmosphereRimWidth * thickness)));
    }

    half fade = 1.0h - smoothstep(0.0h, kAtmosphereTransitionFadeEnd, half(atmosphere.transition));

    // Premultiplied output over what is behind: the color is the halo tint,
    // whitened toward the limb, weighted by the brightness; the alpha is the
    // brightness itself, so the halo covers the limb and thins to nothing
    // both into space and over the map, and stars right behind the air dim
    // under it.
    half3 tint = mix(half3(atmosphere.color), half3(1.0h), whiten * kAtmosphereWhitenWeight);
    half coverage = brightness * half(atmosphere.intensity) * fade;
    return half4(tint * coverage, saturate(coverage));
}
