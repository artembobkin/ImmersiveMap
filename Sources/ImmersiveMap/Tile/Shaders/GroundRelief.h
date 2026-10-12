// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GroundRelief.h
//  ImmersiveMap
//
//  The ground relief as the vertex stages read it (GroundReliefStore): the
//  vector ground (Tile.metal, kTileGroundRelief) and the raster ground
//  (TileRaster.metal, kTileRasterRelief) rise by the same sample of the
//  same terrain.
//

#ifndef GROUND_RELIEF
#define GROUND_RELIEF

#include <metal_stdlib>
using namespace metal;

// Where a tile lies in its terrain texture and how high its terrain draws
// (FlatMapSurfaceDrawer and RasterTileRenderSubsystem, vertex buffer 9,
// mirrored by GroundReliefUniform): the tile's north-west corner and side
// in the texture's 0...1, the world units a metre of terrain rises by, at
// the tile's latitude, times the exaggeration, and the datum: the
// terrain's metres under the point the camera looks at, which the ground
// is drawn from, so that point lies on the ground at the origin
// (GroundReliefCameraLift).
struct GroundReliefUniform {
    float2 origin;
    float scale;
    float worldUnitsPerMetre;
    float datumMetres;
};

// The terrain's height in metres under a tile-local point: one bilinear
// sample of the half-float texture. The point is render space (y up), the
// texture's row 0 is the north edge.
static inline float groundReliefHeight(float2 localPosition,
                                       texture2d<float> heights,
                                       GroundReliefUniform relief) {
    constexpr sampler reliefSampler(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 tileUV = float2(localPosition.x, 4096.0 - localPosition.y) / 4096.0;
    float2 textureUV = relief.origin + saturate(tileUV) * relief.scale;
    return heights.sample(reliefSampler, textureUV, level(0.0)).r;
}

// The world z a tile-local point rises to over the plane: its terrain's
// height over the datum, in world units.
static inline float groundReliefLift(float2 localPosition,
                                     texture2d<float> heights,
                                     GroundReliefUniform relief) {
    return (groundReliefHeight(localPosition, heights, relief) - relief.datumMetres) * relief.worldUnitsPerMetre;
}

#endif
