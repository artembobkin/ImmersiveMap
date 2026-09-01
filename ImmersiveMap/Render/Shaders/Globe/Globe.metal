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
    float absLatitude;
    float longitude;
};

struct CapParams {
    float4 edgeColor;
    float4 fillColor;
    float blendStartAbsLatitude;
    float blendEndAbsLatitude;
};

/// How a cap reads its edge strip (GlobeCapEdgeStrip: the tiles' polar edge
/// row, one texel high and a turn of longitude wide, with mips down to one
/// texel). Mirrors GlobeCapStripUniform.swift.
struct GlobeCapStrip {
    uint hasStrip;
    float poleMeanLod;
    float2 padding;
};

constant float kGlobeCapStripWidth = 4096.0;
constant float kGlobeCapStripMaxLod = 12.0;

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
    out.absLatitude = abs(lat);
    out.longitude = lon;
    return out;
}

fragment half4 globeCapFragmentShader(CapVertexOut in [[stage_in]],
                                      texture2d<half> strip [[texture(0)]],
                                      constant CapParams& params [[buffer(0)]],
                                      constant GlobeCapStrip& capStrip [[buffer(3)]]) {
    constexpr sampler stripSampler(filter::linear, mip_filter::linear, mag_filter::linear, address::repeat);

    // The mip level the rim is read at, from the screen derivative of the
    // longitude, which is what the strip advances with along the rim. Taken
    // through (cos, sin) so the longitude wrap adds no false derivative, and
    // explicit rather than automatic: automatic LOD explodes near the pole
    // (meridians converge to a point). Computed before any divergent flow,
    // since derivatives need the whole quad.
    float2 longitudeDirection = float2(cos(in.longitude), sin(in.longitude));
    float radiansPerPixel = max(length(dfdx(longitudeDirection)), length(dfdy(longitudeDirection)));
    float texelsPerPixel = radiansPerPixel * kGlobeCapStripWidth / (2.0 * M_PI_F);
    float lod = clamp(log2(max(texelsPerPixel, 1e-6)), 0.0, kGlobeCapStripMaxLod);

    half seamBlend = half(smoothstep(params.blendStartAbsLatitude,
                                     params.blendEndAbsLatitude,
                                     in.absLatitude));
    half capAlpha = half(in.capAlpha);
    half4 color;
    if (capStrip.hasStrip != 0) {
        // One turn of longitude across the strip; the sampler wraps the
        // angle. Opaque: the cap is surface, and a strip texel's own alpha
        // over black space would read as a dark disc at the pole.
        float2 stripUV = float2(in.longitude / (2.0 * M_PI_F), 0.5);
        half3 rim = strip.sample(stripSampler, stripUV, level(lod)).rgb;
        // Feather toward the windowed mean of the rim (a deeper mip, one
        // texel per tile of the pole row): the edge row continues the
        // surface at the rim (seamBlend 0) but does not reach the pole as
        // "needles", the radial stripes narrow coastal features of the rim
        // would otherwise smear across the whole cap. The mean is what the
        // tiles show at this zoom, not a palette colour, so a pole painted
        // white by the low-zoom land cover and open water by the detailed
        // layers fades into the right one either way.
        half3 pole = strip.sample(stripSampler, stripUV, level(capStrip.poleMeanLod)).rgb;
        color = half4(mix(rim, pole, seamBlend), 1.0h);
    } else {
        color = mix(half4(params.edgeColor), half4(params.fillColor), seamBlend);
    }
    color.a *= capAlpha;
    return color;
}
