// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GroundRelief.h
//  ImmersiveMap
//
//  The ground relief as the vertex stages read it (GroundReliefStore): the
//  vector ground (Tile.metal, kTileGroundRelief) and the raster ground
//  (TileRaster.metal, kTileRasterRelief) rise by the same sample of the
//  same terrain, scaled by the same strength.
//

#ifndef GROUND_RELIEF
#define GROUND_RELIEF

#include <metal_stdlib>
using namespace metal;

// Where a tile lies in its terrain texture and how high its terrain draws
// this frame (FlatMapSurfaceDrawer and RasterTileRenderSubsystem, vertex
// buffer 9, mirrored by GroundReliefUniform):
// - placement: the tile's north-west corner and side in the terrain
//   texture's 0...1, and the world units a metre of terrain rises by at the
//   tile's latitude, the exaggeration not in it.
// - frame: the datum, the terrain's metres under the point the camera
//   looks at, which the ground is drawn from, so that point lies on the
//   ground at the origin (GroundReliefCameraLift), and the strength, the
//   configured exaggeration times what the zoom fades leave this frame
//   (GroundReliefStore.setFrame).
struct GroundReliefUniform {
    float4 placement;
    float4 frame;
};

constexpr sampler groundReliefSampler(filter::linear, address::clamp_to_edge, coord::normalized);

// The texture's uv of a tile-local point: the point is render space (y
// up), the texture's row 0 is the north edge.
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

// The world z a tile-local point rises to over the plane: its terrain's
// height over the datum, in world units, at the frame's strength.
static inline float groundReliefLift(float2 localPosition,
                                     texture2d<float> heights,
                                     GroundReliefUniform relief) {
    float metres = groundReliefHeight(localPosition, heights, relief) - relief.frame.x;
    return metres * relief.frame.y * relief.placement.w;
}

#endif
