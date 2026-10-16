// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GroundRelief.h
//  ImmersiveMap
//
//  The ground relief as the vertex stages read it (GroundReliefStore): the
//  vector ground (Tile.metal, kTileGroundRelief) and the raster ground
//  (TileRaster.metal, kTileRasterRelief) rise by the same sample of the
//  same terrain, scaled by the same strength. Their fills' fragment stages
//  shade the slopes of the same terrain (groundReliefHillshade).
//

#ifndef GROUND_RELIEF
#define GROUND_RELIEF

#include <metal_stdlib>
using namespace metal;

// Where a tile lies in its terrain texture, how high its terrain draws
// this frame and how its slopes are shaded (FlatMapSurfaceDrawer and
// RasterTileRenderSubsystem, vertex and fragment buffer 9, mirrored by
// GroundReliefUniform):
// - placement: the tile's north-west corner and side in the terrain
//   texture's 0...1, and the world units a metre of terrain rises by, the
//   frame's for every tile (GroundReliefStore.worldUnitsPerMetre), the
//   exaggeration not in it.
// - frame: the datum, the terrain's metres under the point the camera
//   looks at, which the ground is drawn from, so that point lies on the
//   ground at the origin (GroundReliefCameraLift), the strength, the
//   configured exaggeration times what the zoom fades leave this frame
//   (GroundReliefStore.setFrame), and the ground metres the terrain
//   texture spans a side.
// - hillshadeLight: the direction toward the scene's light in the flat
//   basis (+x east, +y north, +z up), unit length, and the amount of
//   shading, zero for none (GroundReliefHillshade).
// - hillshadeShadowColor, hillshadeHighlightColor: the colours a slope
//   turned away from the light and toward it are drawn toward, the alpha
//   capping how far.
// - hillshadeEye: the eye in the world, which the fade is measured from.
// - hillshadeFade: the world distance from the eye the shading starts to
//   fade at, and one over the distance it takes to fade out.
struct GroundReliefUniform {
    float4 placement;
    float4 frame;
    float4 hillshadeLight;
    float4 hillshadeShadowColor;
    float4 hillshadeHighlightColor;
    float4 hillshadeEye;
    float4 hillshadeFade;
};

constexpr sampler groundReliefSampler(filter::linear, address::clamp_to_edge, coord::normalized);

// The texture's uv of a tile-local point: the point is render space (y
// up), the texture's row 0 is the north edge.
static inline float2 groundReliefTileUV(float2 localPosition) {
    return saturate(float2(localPosition.x, 4096.0 - localPosition.y) / 4096.0);
}

// Where a tile-local point lies in the terrain texture, in its 0...1.
static inline float2 groundReliefTextureUV(float2 localPosition, GroundReliefUniform relief) {
    return relief.placement.xy + groundReliefTileUV(localPosition) * relief.placement.z;
}

// The terrain's height in metres under a tile-local point: one bilinear
// sample of the half-float texture.
static inline float groundReliefHeight(float2 localPosition,
                                       texture2d<float> heights,
                                       GroundReliefUniform relief) {
    return heights.sample(groundReliefSampler, groundReliefTextureUV(localPosition, relief), level(0.0)).r;
}

// The world z a tile-local point rises to over the plane: its terrain's
// height over the datum, in world units, at the frame's strength.
static inline float groundReliefLift(float2 localPosition,
                                     texture2d<float> heights,
                                     GroundReliefUniform relief) {
    float metres = groundReliefHeight(localPosition, heights, relief) - relief.frame.x;
    return metres * relief.frame.y * relief.placement.w;
}

// A colour of the ground with its slope shaded at a point of the terrain
// texture (textureUV, groundReliefTextureUV): the slope is the terrain's
// own, the heights a texel to each side, so it is as fine as the terrain
// and not as coarse as the grid the ground rises on. Level ground keeps
// its colour. A slope is lit by how much more or less it faces the light
// than level ground does: turned toward it, the colour is drawn toward the
// highlight, up to all the way for a slope that faces the light square on,
// and turned away, toward the shadow, up to all the way for a slope the
// light only grazes or misses. The slope is the terrain's true one, not
// the relief's exaggeration, which is the vertex stage's. The shading is
// the near ground's: it fades out with the distance of the point
// (worldPosition) from the eye, where a pixel spans many heights and the
// slopes would only shimmer, and past the fade the terrain is not read.
static inline half3 groundReliefHillshade(half3 color,
                                          float2 textureUV,
                                          float3 worldPosition,
                                          texture2d<float> heights,
                                          GroundReliefUniform relief) {
    float faded = saturate((distance(worldPosition, relief.hillshadeEye.xyz) - relief.hillshadeFade.x)
                           * relief.hillshadeFade.y);
    float amount = relief.hillshadeLight.w * (1.0 - faded * faded * (3.0 - 2.0 * faded));
    if (amount <= 0.0) {
        return color;
    }
    float2 texel = 1.0 / float2(heights.get_width(), heights.get_height());
    float east = heights.sample(groundReliefSampler, textureUV + float2(texel.x, 0.0), level(0.0)).r
        - heights.sample(groundReliefSampler, textureUV - float2(texel.x, 0.0), level(0.0)).r;
    // The texture's rows run south.
    float north = heights.sample(groundReliefSampler, textureUV - float2(0.0, texel.y), level(0.0)).r
        - heights.sample(groundReliefSampler, textureUV + float2(0.0, texel.y), level(0.0)).r;
    float2 span = 2.0 * texel * max(relief.frame.z, 1e-3);
    float3 normal = normalize(float3(-east / span.x, -north / span.y, 1.0));
    float3 light = relief.hillshadeLight.xyz;
    // Zero on level ground, one for a slope square to the light, minus one
    // for one the light grazes.
    float facing = dot(normal, light) - light.z;
    float lit = facing >= 0.0 ? facing / max(1.0 - light.z, 1e-3) : facing / max(light.z, 1e-3);
    float4 tint = lit >= 0.0 ? relief.hillshadeHighlightColor : relief.hillshadeShadowColor;
    float share = saturate(abs(lit) * amount) * tint.a;
    return half3(mix(float3(color), tint.rgb, share));
}

#endif
