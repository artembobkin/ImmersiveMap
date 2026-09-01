// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeSurfaceShading.h
//  ImmersiveMap
//
//  The lighting of the globe surface, shared by the placeholder grid and the
//  atlas surface in Globe.metal and by the tile geometry drawn straight on
//  the sphere in TileSphere.metal, so every surface of the planet is lit the
//  same way whatever painted it.
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"

#ifndef GLOBE_SURFACE_SHADING
#define GLOBE_SURFACE_SHADING

/// The atmosphere's glow on the sphere toward the limb. `facing` is how far the
/// surface turns away from the view (0 face-on, 1 at the limb): the air over
/// it thickens with the angle, so the surface lifts toward the atmosphere tint,
/// and in the last sliver before the edge toward white, where the scattering
/// saturates. Additive, so a dark night side still shows a thin lit rim, and
/// weighted by the atmosphere intensity, which is zero when it is off. The
/// halo painted in space (Atmosphere.metal) continues this from the limb
/// outward, from the same tint, so the edge reads as one thing.
static inline half3 globeAtmosphereSurfaceGlow(half facing,
                                               constant GlobeAtmosphere& atmosphere) {
    half rim = pow(facing, 2.6h);
    half edge = pow(facing, 9.0h);
    half3 glow = half3(atmosphere.color) * rim * 0.40h + half3(1.0h) * edge * 0.24h;
    return glow * half(atmosphere.intensity);
}

/// Everything the globe surface does to a sampled color: day/night shading, the
/// limb glow, and the haze that hides the seam at the surface swap. Shared so
/// the placeholder fill is lit exactly like the tile geometry drawn over it
/// (TileSphere.metal), and a tile arriving over it changes only the colour,
/// never the shading. `worldPos` is the morphed surface position, `normal` the
/// rotated unit sphere direction (pan applied), `earthNormal` the earth-fixed
/// one for the sun, `transitionPhase` the globe uniform's transition.
/// Unit-range shading runs in half; view direction and fog distances stay
/// float because they run on world positions.
static inline half4 globeSurfaceShade(half4 color,
                                      float3 worldPos,
                                      float3 normal,
                                      float3 earthNormal,
                                      float transitionPhase,
                                      constant Camera& camera,
                                      constant EarthScene& earthScene,
                                      constant HorizonFog& horizonFog,
                                      constant GlobeAtmosphere& atmosphere) {
    half transition = half(transitionPhase);
    float3 viewDir = normalize(camera.eye - worldPos);
    half facingDot = half(dot(normal, viewDir));
    if (earthScene.isEnabled != 0) {
        half sunDot = half(dot(normalize(earthNormal), normalize(earthScene.sunDirection)));
        half terminatorFadeWidth = half(earthScene.terminatorFadeWidth);
        half dayFactor = smoothstep(-terminatorFadeWidth,
                                    terminatorFadeWidth,
                                    sunDot);
        half dayBrightness = mix(half(earthScene.daySideMinimumBrightness), 1.0h, dayFactor);
        half surfaceBrightness = mix(half(earthScene.nightSideBrightness), dayBrightness, dayFactor);
        surfaceBrightness = mix(surfaceBrightness, 1.0h, transition);
        surfaceBrightness = mix(surfaceBrightness, 1.0h, half(earthScene.sunShadowFade));
        color.rgb *= surfaceBrightness;
        // Rim light: with the sun behind the planet its last sliver of day
        // lies along the limb, and the air there scatters the low sun forward
        // into a warm edge (the planet joins the lit ring in space rather
        // than sitting as a dark disc under it). Confined to the limb and to
        // the band just past the terminator, so a face-on day side is not
        // tinted, and it goes with the terminator and the unfurl.
        // It is forward scattering, so it needs the sun on the far side of
        // the air from the eye: with the sun behind the camera the whole limb
        // has the same grazing angle and would bloom all the way round.
        half rim = pow(max(0.0h, 1.0h - facingDot), 4.0h);
        half dawnBand = smoothstep(-0.10h, 0.12h, sunDot) * (1.0h - smoothstep(0.30h, 0.70h, sunDot));
        half forward = smoothstep(0.0h, 0.45h, half(-dot(atmosphere.sunDirection, viewDir)));
        half rimLight = rim * dawnBand * forward
            * (1.0h - half(earthScene.sunShadowFade))
            * (1.0h - transition)
            * half(atmosphere.intensity);
        color.rgb += half3(1.0h, 0.80h, 0.55h) * rimLight * 0.7h;
    }

    half facing = max(0.0h, 1.0h - facingDot);
    // The glow belongs to the sphere: it fades with the unfurl, since a plane
    // has no limb for the air to thicken toward.
    color.rgb += globeAtmosphereSurfaceGlow(facing, atmosphere) * (1.0h - transition);
    // The haze is gated by the transition phase (strength = transition): a pure
    // globe in space stays fog-free, and by the moment the surfaces swap, the
    // morph and the plane are fogged identically - the horizon-line seam is hidden.
    color.rgb = applyHorizonFog(color.rgb, horizonFog, worldPos);
    return color;
}

#endif
