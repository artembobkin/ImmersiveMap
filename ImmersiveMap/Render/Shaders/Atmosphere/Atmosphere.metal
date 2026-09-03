// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"

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

// The sky of the flat presentation: one fullscreen triangle at the far
// plane, drawn after the ground under a lessEqual depth test, so it paints
// only where nothing else did (above the horizon, and any hole in the
// coverage). Per pixel the view ray's angle to the ground plane's horizon
// selects the horizon haze profile: above the line the sky deepens from
// the whitened horizon tint to the halo blue, below it the pixel gets the
// haze the ground would have worn there, so the coverage edge and the
// horizon line meet in one colour. During the unfurl it blends in with the
// transition, the way the ground fog does, so the surface switch happens
// between identical skies.
//
// Layout mirrors FlatSkyUniform.swift.
struct FlatSky {
    float4x4 inverseViewProjection;
    HorizonFog fog;
};

fragment half4 flatSkyFragmentShader(AtmosphereVertexOut in [[stage_in]],
                                     constant FlatSky& sky [[buffer(0)]]) {
    float4 farPoint = sky.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 direction = normalize(farPoint.xyz / farPoint.w - sky.fog.eye);
    float elevation = asin(clamp(direction.z, -1.0, 1.0));
    float3 color = elevation >= 0.0
        ? horizonSkyColor(sky.fog, elevation)
        : horizonHoleColor(sky.fog, -elevation);
    half alpha = half(sky.fog.strength);
    return half4(half3(color) * alpha, alpha);
}

// The luminous body of the planet, drawn right after the stars and BEFORE
// the tiles: a coarse opaque sphere at the very back of the rank-depth
// band, glowing white, so a slot whose tile has not arrived shows lit
// planet instead of open space. Opaque and depth-tested on purpose: the
// tiles' opaque backgrounds sit nearer in the band, so hidden surface
// removal kills the body's fragments wherever the map has painted, and the
// body costs fragments only in the holes it exists to fill. The slight
// polygonality of the coarse silhouette hides under the atmosphere's rim
// glow, exactly like the tile mesh's own edge. During the unfurl the body
// fades out over the same early window as the halo (the sphere it is
// fitted to starts leaving), through the blended variant of the same
// shader.
//
// Layout mirrors GlobeBackdropUniform.swift (pinned by
// AtmosphereUniformLayoutTests).
struct GlobeBackdrop {
    float4x4 sphereClip;
    float4x4 sphereWorld;
    float3 eye;
    float fade;
};

struct GlobeBackdropVertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPos;
};

vertex GlobeBackdropVertexOut globeBackdropVertexShader(uint vertexID [[vertex_id]],
                                                        constant packed_float3* unitDirections [[buffer(0)]],
                                                        constant GlobeBackdrop& backdrop [[buffer(1)]]) {
    float3 unitDirection = float3(unitDirections[vertexID]);
    GlobeBackdropVertexOut out;
    out.position = backdrop.sphereClip * float4(unitDirection, 1.0);
    // The very back of the band: farther than every tile rank, so a loaded
    // slot's background always wins the pixel.
    out.position.z = out.position.w;
    // The sphere's normal is its unit direction; sphereWorld's linear part
    // is rotation times uniform scale, so the rotated direction stays the
    // normal after normalization.
    out.worldNormal = (backdrop.sphereWorld * float4(unitDirection, 0.0)).xyz;
    out.worldPos = (backdrop.sphereWorld * float4(unitDirection, 1.0)).xyz;
    return out;
}

constant half kGlobeBackdropBody = 0.94h;
constant half kGlobeBackdropRimBoost = 0.3h;

static inline half3 globeBackdropColor(GlobeBackdropVertexOut in, constant GlobeBackdrop& backdrop) {
    float3 normal = normalize(in.worldNormal);
    float3 toEye = normalize(backdrop.eye - in.worldPos);
    // Brighter toward the limb, where the viewer looks through more air:
    // the body reads as a planet full of light, not flat paint.
    half rim = half(pow(1.0 - abs(dot(normal, toEye)), 2.0));
    half brightness = kGlobeBackdropBody + kGlobeBackdropRimBoost * rim;
    return min(half3(brightness), half3(1.0h));
}

fragment half4 globeBackdropFragmentShader(GlobeBackdropVertexOut in [[stage_in]],
                                           constant GlobeBackdrop& backdrop [[buffer(1)]]) {
    return half4(globeBackdropColor(in, backdrop), 1.0h);
}

// The unfurl's fade frames: same body, premultiplied by the fade, blended.
fragment half4 globeBackdropFadeFragmentShader(GlobeBackdropVertexOut in [[stage_in]],
                                               constant GlobeBackdrop& backdrop [[buffer(1)]]) {
    half fade = half(backdrop.fade);
    return half4(globeBackdropColor(in, backdrop) * fade, fade);
}
