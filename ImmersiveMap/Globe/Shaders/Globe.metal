// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "GlobeTransitionProjection.h"

struct CapVertexIn {
    float2 latLon [[attribute(0)]];
};

struct CapVertexOut {
    float4 position [[position]];
    float capAlpha;
};

/// One cap's constant colour, straight from the style palette (the north cap
/// is the open ocean, the south the polar ice); mirrors GlobeCapParams in
/// GlobeCapRenderer.swift.
struct CapParams {
    float4 color;
};

vertex CapVertexOut globeCapVertexShader(CapVertexIn vertexIn [[stage_in]],
                                         constant Globe& globe [[buffer(2)]],
                                         constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    float lat = vertexIn.latLon.x;
    float lon = vertexIn.latLon.y;

    // Cap geometry stores geographic latitude directly. The globe tile path uses
    // phi = geographicLatitude - pi/2 after Mercator->sphere conversion, so caps
    // must use the same convention or north/south hemispheres get swapped. The
    // longitude keeps the cap's own origin: the strip u and the fragment's LOD
    // are indexed with it.
    float phi = lat - M_PI_2_F;
    float theta = lon;
    float3 unitDirection = float3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta));

    // One composed matrix (camera x translate x pan rotation x radius), built
    // once per frame on the CPU: the same path the tile vertices take, instead
    // of rebuilding the pan rotation and the translation per vertex.
    float4 clip = globeFrame.sphereClip * float4(unitDirection, 1.0);
    
    // The cap does not morph into the plane: during the unfurl it diverges from
    // the tile surface, so it fades out in the first third of the transition,
    // while the divergence is not yet noticeable.
    const float capFadeEndTransition = 0.35;
    float transitionFade = smoothstep(0.0, capFadeEndTransition, clamp(globe.transition, 0.0, 1.0));

    CapVertexOut out;
    out.position = clip;
    out.capAlpha = 1.0 - transitionFade;
    return out;
}

fragment half4 globeCapFragmentShader(CapVertexOut in [[stage_in]],
                                      constant CapParams& params [[buffer(0)]]) {
    // Opaque surface colour: the cap is planet, and only the unfurl's fade
    // thins it out (it diverges from the tile surface mid-morph).
    half4 color = half4(half3(params.color.rgb), 1.0h);
    color.a *= half(in.capAlpha);
    return color;
}
