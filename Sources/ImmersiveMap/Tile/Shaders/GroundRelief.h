// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GroundRelief.h
//  ImmersiveMap
//
//  The ground relief as the vertex stages read it (GroundReliefStore): the
//  vector ground (Tile.metal, kTileGroundRelief) and the raster ground
//  (TileRaster.metal, kTileRasterRelief) rise by the same sample of the
//  same terrain, scaled by the same strength of the same place.
//

#ifndef GROUND_RELIEF
#define GROUND_RELIEF

#include <metal_stdlib>
using namespace metal;

// Where a tile lies in its terrain texture and in its roughness texture,
// and how high its terrain draws this frame (FlatMapSurfaceDrawer and
// RasterTileRenderSubsystem, vertex buffer 9, mirrored by
// GroundReliefUniform):
// - placement: the tile's north-west corner and side in the terrain
//   texture's 0...1, and the world units a metre of terrain rises by at the
//   tile's latitude, the exaggeration not in it.
// - roughness: the tile's corner and side in the roughness texture's
//   0...1 (GroundReliefRoughness), and the datum, the terrain's metres
//   under the point the camera looks at, which the ground is drawn from,
//   so that point lies on the ground at the origin (GroundReliefCameraLift).
// - fades: the flat fade's zero-alpha and full-alpha zooms, then the
//   mountain fade's (GroundReliefFrame).
// - frame: the camera zoom and the strength scale, the configured
//   exaggeration times the appear fade's alpha.
struct GroundReliefUniform {
    float4 placement;
    float4 roughness;
    float4 fades;
    float4 frame;
};

constexpr sampler groundReliefSampler(filter::linear, address::clamp_to_edge, coord::normalized);

// The texture's uv of a tile-local point: the point is render space (y
// up), the textures' row 0 is the north edge.
static inline float2 groundReliefTileUV(float2 localPosition) {
    return saturate(float2(localPosition.x, 4096.0 - localPosition.y) / 4096.0);
}

// The terrain's height in metres under a tile-local point: one bilinear
// sample of the half-float texture.
static inline float groundReliefHeight(float2 localPosition,
                                       texture2d<float> heights,
                                       GroundReliefUniform relief) {
    float2 textureUV = relief.placement.xy + groundReliefTileUV(localPosition) * relief.placement.z;
    return heights.sample(groundReliefSampler, textureUV, level(0.0)).r;
}

// How much of a mountain the ground under a tile-local point is, 0 to 1:
// one bilinear sample of the roughness texture.
static inline float groundReliefMountainShare(float2 localPosition,
                                              texture2d<float> roughness,
                                              GroundReliefUniform relief) {
    float2 textureUV = relief.roughness.xy + groundReliefTileUV(localPosition) * relief.roughness.z;
    return roughness.sample(groundReliefSampler, textureUV, level(0.0)).r;
}

// How much taller than the terrain a place of `mountainShare` is drawn
// this frame (GroundReliefFrame.strength): the two fades' zooms blended
// by the share, a smoothstep of the camera zoom between them, times the
// strength scale.
static inline float groundReliefStrength(float mountainShare, float4 fades, float4 frame) {
    float2 zeroFull = mix(fades.xy, fades.zw, saturate(mountainShare));
    float progress = saturate((frame.x - zeroFull.x) / (zeroFull.y - zeroFull.x));
    return progress * progress * (3.0 - 2.0 * progress) * frame.y;
}

// The world z a tile-local point rises to over the plane: its terrain's
// height over the datum, in world units, at the strength of the place.
static inline float groundReliefLift(float2 localPosition,
                                     texture2d<float> heights,
                                     texture2d<float> roughness,
                                     GroundReliefUniform relief) {
    float metres = groundReliefHeight(localPosition, heights, relief) - relief.roughness.w;
    float strength = groundReliefStrength(groundReliefMountainShare(localPosition, roughness, relief),
                                          relief.fades, relief.frame);
    return metres * strength * relief.placement.w;
}

#endif
