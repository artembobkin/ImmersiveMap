// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "GlobeTransitionProjection.h"
#include "GlobeSurfaceShading.h"

// Add necessary structures for transformation and rendering
struct VertexIn {
    float2 uv [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float3 worldPos;
    float transition;
    float3 earthNormal;
};

struct CapVertexIn {
    float2 latLon [[attribute(0)]];
};

struct CapVertexOut {
    float4 position [[position]];
    float capAlpha;
    float absLatitude;
    float latitude;
    float longitude;
    float3 normal;
    float3 worldPos;
    float3 earthNormal;
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

/// The slot a placeholder fill covers; mirrors GlobeSurfaceSlotUniform.swift.
struct Tile {
    int3 tile;
};


vertex VertexOut globeVertexShader(VertexIn vertexIn [[stage_in]],
                                   constant Camera& camera [[buffer(1)]],
                                   constant Globe& globe [[buffer(2)]],
                                   constant Tile& tileData [[buffer(3)]]) {
    
    float vertexUvX = vertexIn.uv.x; // goes 0 to 1
    float vertexUvY = vertexIn.uv.y; // goes 0 to 1
    
    int tileX = tileData.tile.x;
    int tileY = tileData.tile.y;
    int tileZ = tileData.tile.z;
    
    float zPow = pow(2.0, tileZ);
    float size = 1.0 / zPow;
    
    vertexUvX = vertexUvX / zPow + size * tileX;
    
    float latNorth = atan(sinh(M_PI_F * (1.0 - 2.0 * tileY / zPow)));
    float latSouth = atan(sinh(M_PI_F * (1.0 - 2.0 * (tileY + 1) / zPow)));
    float vNorth = 1.0 - (latNorth + M_PI_2_F) / M_PI_F;
    float vSouth = 1.0 - (latSouth + M_PI_2_F) / M_PI_F;
    float vSize = abs(vSouth - vNorth);
    vertexUvY = vNorth + vertexUvY * vSize;
    
    
    float transition = globe.transition; // from globe view to flat view
    
    
    // Map coordinates
    float latitude = globeTransitionPanLatitude(globe);
    float longitude = globeTransitionPanLongitude(globe);
    
    float globeRadius = globe.radius;
    
    float4x4 matrix = camera.matrix;
    
    float mapSize = globeTransitionMapSize(globe, latitude);
    
    float phi = -M_PI_F * vertexUvY;
    float theta = 2 * M_PI_F * vertexUvX;
     
    float x = globeRadius * sin(phi) * sin(theta);
    float y = globeRadius * cos(phi);
    float z = globeRadius * sin(phi) * cos(theta);
    float3 spherePosition = float3(x, y, z);
    
    
    // Rotate the planet
    float cx = cos(-latitude);
    float sx = sin(-latitude);
    float cy = cos(-longitude);
    float sy = sin(-longitude);

    float4x4 rotation = float4x4(
        float4(cy,        0,         -sy,       0),
        float4(sy * sx,   cx,        cy * sx,   0),
        float4(sy * cx,  -sx,        cy * cx,   0),
        float4(0,         0,          0,        1)
    );


    // Convert globePanY (-1..1) to a Mercator-aligned vertical pan so the flat map
    float panY_merc_norm = globeTransitionPanMercatorY(latitude);
    
    // `vertexUvY` grows top-to-bottom, so this intermediate latitude is sign-inverted
    // relative to geographic latitude and needs the extra negation below.
    float lat_v = M_PI_F * vertexUvY - M_PI_2_F;      // [-pi/2..pi/2]
    float flatMercatorY = -getYMercNorm(lat_v);       // geographic-Mercator sign in flat world space
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(vertexUvX,
                                                                flatMercatorY,
                                                                globe,
                                                                mapSize,
                                                                panY_merc_norm);
    
    float4x4 translationM = translationMatrix(float3(0, 0, -globeRadius));
    float4 spherePositionTranslated = float4(spherePosition, 1.0) * rotation * translationM;
    float4 flatPosition = float4(flatWorldPosition, 0, 1.0);
    float3 rotatedSphereDirection = normalize((float4(spherePosition, 0.0) * rotation).xyz);
    float localTransition = globeTransitionLocalPhase(transition, rotatedSphereDirection.z);
    float4 position = mix(spherePositionTranslated, flatPosition, localTransition);
    float4 clip = matrix * position;

    VertexOut out;
    // Keep clip-space position; GPU performs the perspective divide.
    out.position = clip;
    out.normal = rotatedSphereDirection;
    // The morphed position, not the spherical one: fog is computed from it, and
    // its distances must match the flat path (on the sphere chords are shorter,
    // so the fog was thinner, "catching up" with a jump at the swap). At t = 0
    // the values are bit-for-bit equal to the spherical ones, so the limb glow
    // does not change.
    out.worldPos = position.xyz;
    out.transition = transition;
    out.earthNormal = normalize(spherePosition);
    return out;
}

/// A blank tile in the map's own background color, drawn into every visible
/// slot that no content paints yet, before the atlas mappings, writing depth
/// like any other surface.
///
/// Two things depended on the surface being there and had nothing to fall back
/// on while tiles were still loading, or wherever coverage has a hole: the
/// planet read as a see-through shell against space, and the depth buffer had
/// nothing to occlude with. Each fill draws the exact slot geometry its tile
/// will draw, so the tile replaces it at identical depth; a single coarser
/// fill of the whole sphere poked through the finer tile mesh at its own grid
/// vertices as background-colored dots.
fragment half4 globeSurfacePlaceholderFragmentShader(VertexOut in [[stage_in]],
                                                     constant Camera& camera [[buffer(1)]],
                                                     constant EarthScene& earthScene [[buffer(2)]],
                                                     constant HorizonFog& horizonFog [[buffer(4)]],
                                                     constant float4& fillColor [[buffer(5)]],
                                                     constant GlobeAtmosphere& atmosphere [[buffer(6)]],
                                                     constant GlobeSurfaceTone& tone [[buffer(7)]]) {
    return globeSurfaceShade(half4(fillColor), in.worldPos, in.normal, in.earthNormal, in.transition,
                             camera, earthScene, horizonFog, atmosphere, tone);
}

vertex CapVertexOut globeCapVertexShader(CapVertexIn vertexIn [[stage_in]],
                                         constant Camera& camera [[buffer(1)]],
                                         constant Globe& globe [[buffer(2)]]) {
    float lat = vertexIn.latLon.x;
    float lon = vertexIn.latLon.y;
    
    float globeRadius = globe.radius;
    // Cap geometry stores geographic latitude directly. The globe tile path uses
    // phi = geographicLatitude - pi/2 after Mercator->sphere conversion, so caps
    // must use the same convention or north/south hemispheres get swapped.
    float phi = lat - M_PI_2_F;
    float theta = lon;
    
    float x = globeRadius * sin(phi) * sin(theta);
    float y = globeRadius * cos(phi);
    float z = globeRadius * sin(phi) * cos(theta);
    float3 spherePosition = float3(x, y, z);
    
    float maxLatitude = 2.0 * atan(exp(M_PI_F)) - M_PI_2_F;
    float latitude = globe.panY * maxLatitude;
    float longitude = globe.panX * M_PI_F;
    
    float cx = cos(-latitude);
    float sx = sin(-latitude);
    float cy = cos(-longitude);
    float sy = sin(-longitude);
    
    float4x4 rotation = float4x4(
        float4(cy,        0,         -sy,       0),
        float4(sy * sx,   cx,        cy * sx,   0),
        float4(sy * cx,  -sx,        cy * cx,   0),
        float4(0,         0,          0,        1)
    );
    
    float4x4 translationM = translationMatrix(float3(0, 0, -globeRadius));
    float4 spherePositionTranslated = float4(spherePosition, 1.0) * rotation * translationM;
    float4 clip = camera.matrix * spherePositionTranslated;
    
    // The cap does not morph into the plane: during the unfurl it diverges from
    // the tile surface, so it fades out in the first third of the transition,
    // while the divergence is not yet noticeable.
    const float capFadeEndTransition = 0.35;
    float transitionFade = smoothstep(0.0, capFadeEndTransition, clamp(globe.transition, 0.0, 1.0));

    CapVertexOut out;
    out.position = clip;
    out.capAlpha = 1.0 - transitionFade;
    out.absLatitude = abs(lat);
    out.latitude = lat;
    out.longitude = lon;
    out.normal = normalize((float4(spherePosition, 0.0) * rotation).xyz);
    out.worldPos = spherePositionTranslated.xyz;
    out.earthNormal = normalize(spherePosition);
    return out;
}

fragment half4 globeCapFragmentShader(CapVertexOut in [[stage_in]],
                                      texture2d<half> strip [[texture(0)]],
                                      constant CapParams& params [[buffer(0)]],
                                      constant Camera& camera [[buffer(1)]],
                                      constant EarthScene& earthScene [[buffer(2)]],
                                      constant GlobeCapStrip& capStrip [[buffer(3)]],
                                      constant GlobeAtmosphere& atmosphere [[buffer(6)]],
                                      constant GlobeSurfaceTone& tone [[buffer(7)]]) {
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
    // The same deepening as the tiled surface, so the cap continues its
    // colour over the pole at every zoom.
    float3 viewDir = normalize(camera.eye - in.worldPos);
    half facingDot = half(dot(in.normal, viewDir));
    color.rgb = globeSurfaceDeepen(color.rgb, facingDot, tone);

    if (earthScene.isEnabled != 0) {
        half sunDot = half(dot(normalize(in.earthNormal), normalize(earthScene.sunDirection)));
        half terminatorFadeWidth = half(earthScene.terminatorFadeWidth);
        half dayFactor = smoothstep(-terminatorFadeWidth,
                                    terminatorFadeWidth,
                                    sunDot);
        half dayBrightness = mix(half(earthScene.daySideMinimumBrightness), 1.0h, dayFactor);
        half surfaceBrightness = mix(half(earthScene.nightSideBrightness), dayBrightness, dayFactor);
        surfaceBrightness = mix(surfaceBrightness, 1.0h, clamp(1.0h - capAlpha, 0.0h, 1.0h));
        surfaceBrightness = mix(surfaceBrightness, 1.0h, half(earthScene.sunShadowFade));
        color.rgb *= surfaceBrightness;
    }

    half facing = max(0.0h, 1.0h - facingDot);
    // The same glow as the tiled surface, so the cap continues it seamlessly
    // over the pole; it goes with the cap's own fade through the unfurl.
    color.rgb += globeAtmosphereSurfaceGlow(facing, atmosphere) * capAlpha;
    color.a *= capAlpha;
    return color;
}
