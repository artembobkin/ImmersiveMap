// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileRaster.metal
//  ImmersiveMap
//
//  The raster tiles (RasterTileStore): a tile's ground drawn once into a
//  texture, and the texture drawn on a grid in the tile's place.
//
//  - tileRasterBake* draws the tile's fill runs into the texture, top down
//    over the tile's extent: the style's colour in buffer order, its zoom
//    fade evaluated once at the key's fade zoom (RasterTileSpec), not at
//    the live camera's: a raster tile is drawn once.
//  - tileRasterFlat* draws the texture on the plane, at the ground's rank
//    depth, under the ground shadow mask.
//  - tileRasterSpherePure* and tileRasterSphereMorph* draw it on the
//    resting sphere and through the unroll, the projection of
//    TileSphere.metal.
//

#include <metal_stdlib>
using namespace metal;
#include "TileShading.h"
#include "../../Globe/Shaders/GlobeTileProjection.h"

constant float kTileRasterExtent = 4096.0;

// The flat rank depth, one value with Tile.metal (kFlatTileLayerDepthStep,
// kFlatRealDepthScale): the raster tile takes the ground band's first step,
// where the opaque fills of a vector tile lie.
constant float kTileRasterFlatLayerDepthStep = 3.2e-6;
constant float kTileRasterFlatRealDepthScale = 1.0 - 1536.0 * kTileRasterFlatLayerDepthStep;
// The sphere's rank depth step, one value with TileSphere.metal
// (kTileSphereLayerDepthStep): the raster tile takes the first rank.
constant float kTileRasterSphereLayerDepthStep = 3.2e-6;
// Mask pixels per drawable pixel, one value with Tile.metal
// (kGroundShadowMaskScale).
constant float kTileRasterGroundShadowMaskScale = 0.4;

/// The texture coordinate of a tile-local position: x east, v from the
/// tile's north edge, where the texture's first row is.
static inline float2 tileRasterTextureUv(float2 localPosition) {
    return float2(localPosition.x, kTileRasterExtent - localPosition.y) / kTileRasterExtent;
}

// MARK: - Bake

struct TileRasterBakeVertexOut {
    float4 position [[position]];
    half4 color;
};

vertex TileRasterBakeVertexOut tileRasterBakeVertexShader(VertexIn vertexIn [[stage_in]],
                                                          constant Style* styles [[buffer(2)]],
                                                          constant float2* styleZoomFades [[buffer(4)]],
                                                          constant OverviewFadeUniform& fade [[buffer(11)]]) {
    TileRasterBakeVertexOut out;
    // The tile's extent fills the texture: local y up is clip y up, which
    // is the texture's first row at the north edge.
    float2 clip = float2(vertexIn.position.xy) / kTileRasterExtent * 2.0 - 1.0;
    out.position = float4(clip, 0.0, 1.0);
    out.color = half4(styles[vertexIn.styleIndex].color);
    out.color.a *= tileStyleFade(styleZoomFades[vertexIn.styleIndex], fade);
    return out;
}

fragment half4 tileRasterBakeFragmentShader(TileRasterBakeVertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Draw

/// The sampling of a raster tile (RasterTileRenderSubsystem, fragment
/// buffer 1): the bias added to the mip level the GPU picks.
struct TileRasterSampling {
    float mipLevelBias;
};

struct TileRasterVertexOut {
    float4 position [[position]];
    float2 uv;
};

static inline half4 tileRasterColor(float2 uv,
                                    texture2d<half> raster,
                                    sampler rasterSampler,
                                    constant TileRasterSampling& sampling) {
    half4 color = raster.sample(rasterSampler, uv, bias(sampling.mipLevelBias));
    color.a = 1.0h;
    return color;
}

vertex TileRasterVertexOut tileRasterFlatVertexShader(uint vertexID [[vertex_id]],
                                                      constant float2* grid [[buffer(0)]],
                                                      constant Camera& camera [[buffer(1)]],
                                                      constant float4x4& modelMatrix [[buffer(3)]]) {
    float2 localPosition = grid[vertexID];
    TileRasterVertexOut out;
    out.position = camera.matrix * (modelMatrix * float4(localPosition, 0.0, 1.0));
    // The plane's depth scaled to the ground band's first step, as the
    // vector ground's opaque fills (Tile.metal).
    out.position.z *= (1.0 - kTileRasterFlatLayerDepthStep) / kTileRasterFlatRealDepthScale;
    out.uv = tileRasterTextureUv(localPosition);
    return out;
}

fragment half4 tileRasterFlatFragmentShader(TileRasterVertexOut in [[stage_in]],
                                            constant TileRasterSampling& sampling [[buffer(1)]],
                                            constant Shadow& shadow [[buffer(3)]],
                                            texture2d<half> raster [[texture(0)]],
                                            texture2d<half> groundShadowMask [[texture(1)]],
                                            sampler rasterSampler [[sampler(0)]]) {
    half4 color = tileRasterColor(in.uv, raster, rasterSampler, sampling);
    // The ground shadow mask, read as the vector ground reads it
    // (tileGroundShadowFactor in Tile.metal).
    constexpr sampler maskSampler(coord::pixel, filter::linear, address::clamp_to_edge);
    float shadowFactor = shadow.strength > 0.0
        ? float(groundShadowMask.sample(maskSampler, in.position.xy * kTileRasterGroundShadowMaskScale).r)
        : 1.0;
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    return color;
}

/// Mirror of GlobeSurfaceTileUniform.swift, as TileSphere.metal declares it.
struct TileRasterSurfaceTile {
    float2 uvOrigin;
    float uvScale;
    float referenceWorldX;
};

static inline float2 tileRasterWorldUv(float2 localPosition, constant TileRasterSurfaceTile& surfaceTile) {
    return surfaceTile.uvOrigin + tileRasterTextureUv(localPosition) * surfaceTile.uvScale;
}

vertex TileRasterVertexOut tileRasterSpherePureVertexShader(uint vertexID [[vertex_id]],
                                                            constant float2* grid [[buffer(0)]],
                                                            constant TileRasterSurfaceTile& surfaceTile [[buffer(9)]],
                                                            constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    float2 localPosition = grid[vertexID];
    float3 unitDirection = globeWorldUVUnitDirection(tileRasterWorldUv(localPosition, surfaceTile));
    TileRasterVertexOut out;
    out.position = globeFrame.sphereClip * float4(unitDirection, 1.0);
    out.position.z = (1.0 - kTileRasterSphereLayerDepthStep) * out.position.w;
    out.uv = tileRasterTextureUv(localPosition);
    return out;
}

struct TileRasterMorphVertexOut {
    float4 position [[position]];
    // The unroll's cut, as tileSphereMorphVertexShader's.
    float clipDistance [[clip_distance]] [1];
    float2 uv;
};

vertex TileRasterMorphVertexOut tileRasterSphereMorphVertexShader(uint vertexID [[vertex_id]],
                                                                  constant float2* grid [[buffer(0)]],
                                                                  constant Camera& camera [[buffer(1)]],
                                                                  constant Globe& globe [[buffer(8)]],
                                                                  constant TileRasterSurfaceTile& surfaceTile [[buffer(9)]],
                                                                  constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    float2 localPosition = grid[vertexID];
    float2 worldUv = tileRasterWorldUv(localPosition, surfaceTile);
    float3 unitDirection = globeWorldUVUnitDirection(worldUv);
    float3 sphereWorldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    float mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                                globeFrame.mapSize, globeFrame.panMercatorY,
                                                                surfaceTile.referenceWorldX);
    float3 worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                    globe.transition, globe.radius);
    TileRasterMorphVertexOut out;
    out.position = camera.matrix * float4(worldPosition, 1.0);
    out.position.z = (1.0 - kTileRasterSphereLayerDepthStep) * out.position.w;
    out.clipDistance[0] = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                                  globe.transition, globe.radius);
    out.uv = tileRasterTextureUv(localPosition);
    return out;
}

fragment half4 tileRasterSphereFragmentShader(TileRasterVertexOut in [[stage_in]],
                                              constant TileRasterSampling& sampling [[buffer(1)]],
                                              texture2d<half> raster [[texture(0)]],
                                              sampler rasterSampler [[sampler(0)]]) {
    return tileRasterColor(in.uv, raster, rasterSampler, sampling);
}
