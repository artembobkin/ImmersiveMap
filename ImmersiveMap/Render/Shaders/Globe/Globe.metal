// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "GlobeTransitionProjection.h"
#include "../Shared/AtlasSampling.h"

// Add necessary structures for transformation and rendering
struct VertexIn {
    float2 uv [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float uvSize;
    float posU;
    float posV;
    float lastPos;
    float halfTexel;  // For inset clamping and discard relaxation
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
    float4 sampleOptions;
};

struct Tile {
    int position;
    int textureSize;
    int cellSize;
    int3 tile;
    int3 sourceTile;
};


vertex VertexOut globeVertexShader(VertexIn vertexIn [[stage_in]],
                                   constant Camera& camera [[buffer(1)]],
                                   constant Globe& globe [[buffer(2)]],
                                   constant Tile& tileData [[buffer(3)]]) {
    
    float2 tileLocalUV = vertexIn.uv;
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
    
    
    float textureSize = tileData.textureSize;
    float cellSize = tileData.cellSize;
    int count = textureSize / cellSize;
    
    
    int posU = tileData.position % count;
    int posV = tileData.position / count;
    int lastPos = count - 1;
    
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
    // Compute texture coordinates for blending
    float u = 1.0 - vertexUvX;
    
    int tilesCount = int(zPow);
    int lastTile = tilesCount - 1;
    float sphereV = (-flatMercatorY - 1.0) / -2.0;
    float v = sphereV;
    float t_u = ((1.0 - u) * zPow - tileX + posU) / count;
    float t_v = (1.0 - v * zPow + (lastTile - tileY) + float(lastPos - posV)) / count;
    
    VertexOut out;
    // Keep clip-space position; GPU performs the perspective divide.
    out.position = clip;
    out.texCoord = float2(t_u, t_v);
    out.uvSize = 1.0 / count;
    out.posU = posU;
    out.posV = posV;
    out.lastPos = lastPos;
    out.halfTexel = 0.5 / textureSize;
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

struct GlobeCapAtlasSample {
    float2 uv;
    bool isValid;
};

static float globeCapWrapUnit(float value) {
    return value - floor(value);
}

static GlobeCapAtlasSample globeCapAtlasSampleUV(float latitude,
                                                 float longitude,
                                                 constant Tile& tileData) {
    float textureSize = float(tileData.textureSize);
    float cellSize = float(tileData.cellSize);
    if (textureSize <= 0.0 || cellSize <= 0.0) {
        return GlobeCapAtlasSample{float2(0.0), false};
    }

    int count = int(textureSize / cellSize);
    if (count <= 0) {
        return GlobeCapAtlasSample{float2(0.0), false};
    }

    int tileX = tileData.tile.x;
    int tileY = tileData.tile.y;
    int tileZ = tileData.tile.z;
    float zPow = exp2(float(tileZ));
    float normalizedWorldX = globeCapWrapUnit(longitude / (2.0 * M_PI_F));
    float mercatorY = getYMercNorm(latitude);

    // Only the longitude (X) axis decides which edge-row tile owns this cap wedge.
    // The draw loop already guarantees this tile is the matching pole row
    // (tile.y == 0 for the north cap, lastTileY for the south cap), and every
    // fragment samples the fixed boundary latitude +-maxLatitude, so the vertical
    // atlas coordinate sits exactly on the tile knife-edge (localY == 0 or 1).
    // Testing that against a tight epsilon spuriously fails under GPU float /
    // fast-math rounding and leaves the static fallback color showing at the pole.
    // The returned V is clamped to this tile's edge texel below, so no Y test is
    // needed here.
    float localX = normalizedWorldX * zPow - float(tileX);
    float epsilon = 0.00001;
    if (localX < -epsilon || localX > 1.0 + epsilon) {
        return GlobeCapAtlasSample{float2(0.0), false};
    }

    int position = tileData.position;
    int posU = position % count;
    int posV = position / count;
    int lastPos = count - 1;
    int lastTile = int(zPow) - 1;
    float textureV = (mercatorY + 1.0) * 0.5;
    float u = (normalizedWorldX * zPow - float(tileX) + float(posU)) / float(count);
    float v = (1.0 - textureV * zPow + float(lastTile - tileY) + float(lastPos - posV)) / float(count);

    float uvSize = 1.0 / float(count);
    float halfTexel = 0.5 / textureSize;
    float uMin = float(posU) * uvSize;
    float uMax = uMin + uvSize;
    float vMin = float(lastPos - posV) * uvSize;
    float vMax = 1.0 - float(posV) * uvSize;

    return GlobeCapAtlasSample{
        float2(clamp(u, uMin + halfTexel, uMax - halfTexel),
               clamp(v, vMin + halfTexel, vMax - halfTexel)),
        true
    };
}

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

/// The colour of the surface seen whole from space: the tile palette, pale so
/// labels read over it up close, is pushed toward richer and darker on the
/// small sphere, by `depth` (1 at zoom 0, 0 by zoom 2, see
/// GlobeSurfaceToneUniform.swift). Saturation rises around the luma, then a
/// power curve deepens the midtones while white stays white and black stays
/// black, so coastlines and the sea keep their contrast instead of everything
/// sliding toward grey. Applied to the bare sampled colour, before the
/// day/night shading and the additive limb glow, so the night side and the
/// rim keep their own look on top of it. At depth 0 the colour passes
/// through exactly.
static inline half3 globeSurfaceDeepen(half3 color, constant GlobeSurfaceTone& tone) {
    half depth = clamp(half(tone.depth), 0.0h, 1.0h);
    if (depth <= 0.0h) {
        return color;
    }
    half luma = dot(color, half3(0.299h, 0.587h, 0.114h));
    half3 saturated = clamp(mix(half3(luma), color, 1.0h + 0.55h * depth), 0.0h, 1.0h);
    return pow(saturated, half3(1.0h + 0.45h * depth));
}

/// Everything the globe surface does to a sampled color: day/night shading, the
/// limb glow, and the haze that hides the seam at the surface swap. Shared so
/// the placeholder fill below is lit exactly like the tiles that replace it,
/// and a tile arriving over it changes only the texture, never the shading.
/// Unit-range shading runs in half; view direction and fog distances stay
/// float because they run on world positions.
static inline half4 globeSurfaceShade(half4 color,
                                      VertexOut in,
                                      constant Camera& camera,
                                      constant EarthScene& earthScene,
                                      constant HorizonFog& horizonFog,
                                      constant GlobeAtmosphere& atmosphere,
                                      constant GlobeSurfaceTone& tone) {
    half transition = half(in.transition);
    color.rgb = globeSurfaceDeepen(color.rgb, tone);
    if (earthScene.isEnabled != 0) {
        half sunDot = half(dot(normalize(in.earthNormal), normalize(earthScene.sunDirection)));
        half terminatorFadeWidth = half(earthScene.terminatorFadeWidth);
        half dayFactor = smoothstep(-terminatorFadeWidth,
                                    terminatorFadeWidth,
                                    sunDot);
        half dayBrightness = mix(half(earthScene.daySideMinimumBrightness), 1.0h, dayFactor);
        half surfaceBrightness = mix(half(earthScene.nightSideBrightness), dayBrightness, dayFactor);
        surfaceBrightness = mix(surfaceBrightness, 1.0h, transition);
        surfaceBrightness = mix(surfaceBrightness, 1.0h, half(earthScene.sunShadowFade));
        color.rgb *= surfaceBrightness;
    }

    float3 viewDir = normalize(camera.eye - in.worldPos);
    half facing = half(max(0.0, 1.0 - dot(in.normal, viewDir)));
    // The glow belongs to the sphere: it fades with the unfurl, since a plane
    // has no limb for the air to thicken toward.
    color.rgb += globeAtmosphereSurfaceGlow(facing, atmosphere) * (1.0h - transition);
    // The haze is gated by the transition phase (strength = transition): a pure
    // globe in space stays fog-free, and by the moment the surfaces swap, the
    // morph and the plane are fogged identically - the horizon-line seam is hidden.
    color.rgb = applyHorizonFog(color.rgb, horizonFog, in.worldPos);
    return color;
}

fragment half4 globeFragmentShader(VertexOut in [[stage_in]],
                                   texture2d<half> texture [[texture(0)]],
                                   constant Camera& camera [[buffer(1)]],
                                   constant EarthScene& earthScene [[buffer(2)]],
                                   constant Tile& tileData [[buffer(3)]],
                                   constant HorizonFog& horizonFog [[buffer(4)]],
                                   constant GlobeAtmosphere& atmosphere [[buffer(6)]],
                                   constant GlobeSurfaceTone& tone [[buffer(7)]]) {
    constexpr sampler textureSampler(filter::linear, mip_filter::linear, mag_filter::linear);

    AtlasTileBounds bounds = atlasTileBounds(in.posU, in.posV, in.lastPos, in.uvSize);
    AtlasSampleCoords coords = atlasSampleCoords(in.texCoord, bounds, in.halfTexel);
    if (coords.outsideCoverage) {
        discard_fragment();
    }

    return globeSurfaceShade(texture.sample(textureSampler, coords.uv, level(coords.lod)),
                             in, camera, earthScene, horizonFog, atmosphere, tone);
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
    return globeSurfaceShade(half4(fillColor), in, camera, earthScene, horizonFog, atmosphere, tone);
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
                                      texture2d<half> texture [[texture(0)]],
                                      constant CapParams& params [[buffer(0)]],
                                      constant Camera& camera [[buffer(1)]],
                                      constant EarthScene& earthScene [[buffer(2)]],
                                      constant Tile& tileData [[buffer(3)]],
                                      constant GlobeAtmosphere& atmosphere [[buffer(6)]],
                                      constant GlobeSurfaceTone& tone [[buffer(7)]]) {
    constexpr sampler textureSampler(filter::linear, mip_filter::linear, mag_filter::linear);

    half seamBlend = half(smoothstep(params.blendStartAbsLatitude,
                                     params.blendEndAbsLatitude,
                                     in.absLatitude));
    half capAlpha = half(in.capAlpha);
    half4 color;
    if (params.sampleOptions.y > 0.5) {
        GlobeCapAtlasSample sample = globeCapAtlasSampleUV(params.sampleOptions.x,
                                                           in.longitude,
                                                           tileData);
        if (!sample.isValid) {
            discard_fragment();
            return half4(0.0h);
        }
        // Explicit level(0): the cap smears a single edge row of tile texels,
        // and the base mip is precise and stable. Automatic LOD explodes near
        // the pole (meridians converge to a point, and the longitude wrap makes
        // the uv derivatives discontinuous), so sampling dives into deep atlas
        // mips where texels average neighboring page tiles: a fan of gray
        // wedges across the grid triangles and flicker on every atlas repack.
        half4 sampled = texture.sample(textureSampler, sample.uv, level(0.0));
        // Feather toward the pole color: the edge row continues the surface at
        // the rim (seamBlend 0) but does not reach the pole itself as "needles":
        // narrow coastal features of the rim (e.g. the Ross Sea water at 85°S)
        // would otherwise smear as radial stripes across the whole cap.
        color = mix(sampled, half4(params.fillColor), seamBlend);
    } else {
        color = mix(half4(params.edgeColor), half4(params.fillColor), seamBlend);
    }
    // The same deepening as the tiled surface, so the cap continues its
    // colour over the pole at every zoom.
    color.rgb = globeSurfaceDeepen(color.rgb, tone);

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

    float3 viewDir = normalize(camera.eye - in.worldPos);
    half facing = half(max(0.0, 1.0 - dot(in.normal, viewDir)));
    // The same glow as the tiled surface, so the cap continues it seamlessly
    // over the pole; it goes with the cap's own fade through the unfurl.
    color.rgb += globeAtmosphereSurfaceGlow(facing, atmosphere) * capAlpha;
    color.a *= capAlpha;
    return color;
}
