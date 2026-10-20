// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileRaster.metal
//  ImmersiveMap
//
//  The raster tiles (RasterTileRenderSubsystem): a tile's ground drawn
//  into a texture each frame, and the texture drawn on a grid in the
//  tile's place.
//
//  - tileRasterBake* draws the tile's fill runs into the texture, top down
//    over the tile's extent: the style's colour in buffer order, its zoom
//    fade at the frame's camera zoom, as the vector ground draws it.
//  - tileRasterFlat* draws the texture on the plane, at the ground's rank
//    depth, under the ground shadow mask, or on the relief
//    (kTileRasterRelief), raised as the vector ground is.
//  - tileRasterSpherePure* and tileRasterSphereMorph* draw it on the
//    resting sphere and through the unroll, the projection of
//    TileSphere.metal.
//

#include <metal_stdlib>
using namespace metal;
#include "TileShading.h"
#include "../Relief/Shaders/GroundRelief.h"
#include "../../Globe/Shaders/GlobeTileProjection.h"
#include "../../Globe/Shaders/GlobeLight.h"
#include "../../Render/Shaders/Shared/GroundFog.h"

constant float kTileRasterExtent = 4096.0;

// The flat rank depth, one value with Tile.metal (kFlatTileLayerDepthStep,
// kFlatRealDepthScale): the raster tile lies half a step behind the ground
// band's first step, where the opaque fills of a vector tile lie. Not on
// it: a vector tile drawn over the raster (a finer tile reaching into the
// raster ring, or the raster's own tile placed in a vector slot as a
// stand-in) is then nearer by a margin, and wins its ground outright.
// At the same depth the two met at the last bits of z, interpolated over
// different triangles of the one plane, and the far ground rippled
// between them.
constant float kTileRasterFlatLayerDepthStep = 3.2e-6;
constant float kTileRasterBehindFillsShare = 0.5;
constant float kTileRasterFlatRealDepthScale = 1.0 - 1536.0 * kTileRasterFlatLayerDepthStep;
// The relief's depth, one value with Tile.metal (kReliefBandScale,
// kReliefGroundBehind): the raised ground keeps the real geometry's depth
// scale, at the band's first step.
constant float kTileRasterReliefBandScale = 0.25;
constant float kTileRasterReliefGroundBehind = 2.0 * kTileRasterFlatLayerDepthStep;
// Mask pixels per drawable pixel, one value with Tile.metal
// (kGroundShadowMaskScale).
constant float kTileRasterGroundShadowMaskScale = 0.4;

/// The raster tile on the ground relief (GroundReliefStore): the grid's
/// vertex rises by the terrain's height under it, read from the relief
/// texture, as a flattened vector tile's does (Tile.metal).
constant bool kTileRasterRelief [[function_constant(0)]];
// The sphere's rank depth step, one value with TileSphere.metal
// (kTileSphereLayerDepthStep): the raster tile takes the first rank.
constant float kTileRasterSphereLayerDepthStep = 3.2e-6;
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
    // The plane's point, for the ground fog. Unused on the sphere.
    float3 worldPosition;
    // The sphere's normal in world space, the sun's side (GlobeLight.h).
    // Unused on the plane.
    float3 sphereNormal;
};

// The fragment stage's view of TileRasterVertexOut: the same interpolants
// matched by name.
struct TileRasterFragmentIn {
    float4 position [[position]];
    float2 uv;
    float3 worldPosition;
    float3 sphereNormal;
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
                                                      constant float4x4& modelMatrix [[buffer(3)]],
                                                      constant GroundReliefUniform& relief [[buffer(9), function_constant(kTileRasterRelief)]],
                                                      texture2d<float> reliefHeights [[texture(0), function_constant(kTileRasterRelief)]]) {
    float2 localPosition = grid[vertexID];
    TileRasterVertexOut out;
    float4 worldPosition = modelMatrix * float4(localPosition, 0.0, 1.0);
    if (kTileRasterRelief) {
        worldPosition.z += groundReliefLift(localPosition, reliefHeights, relief);
    }
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    // The plane has no sphere: the light reads nothing there.
    out.sphereNormal = float3(0.0, 0.0, 1.0);
    float step = kTileRasterFlatLayerDepthStep * kTileRasterBehindFillsShare;
    if (kTileRasterRelief) {
        // The relief's depth half a step behind the ground band's first
        // step, where the vector ground's opaque fills over a relief lie
        // (Tile.metal).
        out.position.z *= 1.0 + kTileRasterReliefGroundBehind - step * kTileRasterReliefBandScale;
    } else {
        // The plane's depth scaled to half a step behind the ground band's
        // first step, where the vector ground's opaque fills lie
        // (Tile.metal).
        out.position.z *= (1.0 - step) / kTileRasterFlatRealDepthScale;
    }
    out.uv = tileRasterTextureUv(localPosition);
    return out;
}

fragment half4 tileRasterFlatFragmentShader(TileRasterFragmentIn in [[stage_in]],
                                            constant TileRasterSampling& sampling [[buffer(1)]],
                                            constant Shadow& shadow [[buffer(3)]],
                                            constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]],
                                            texture2d<half> raster [[texture(0)]],
                                            texture2d<half> groundShadowMask [[texture(1)]],
                                            depth2d_array<float> shadowMap [[texture(2), function_constant(kTileRasterRelief)]],
                                            constant GroundReliefUniform& relief [[buffer(9), function_constant(kTileRasterRelief)]],
                                            texture2d<float> reliefHeights [[texture(3), function_constant(kTileRasterRelief)]],
                                            texture2d<float> reliefOcclusion [[texture(4), function_constant(kTileRasterRelief)]],
                                            sampler rasterSampler [[sampler(0)]]) {
    half4 color = tileRasterColor(in.uv, raster, rasterSampler, sampling);
    // The slopes shaded as the vector ground's fills shade them: the
    // texture's uv is the tile's (tileRasterTextureUv, groundReliefTileUV).
    if (kTileRasterRelief) {
        float2 shadingUV = relief.shading.xy + saturate(in.uv) * relief.shading.z;
        color.rgb = groundReliefHillshade(color.rgb, shadingUV, in.worldPosition, reliefHeights, relief);
        color.rgb = groundReliefOcclude(color.rgb, shadingUV, reliefOcclusion, relief);
    }
    // The ground shadow mask, read as the vector ground reads it
    // (tileGroundShadowFactor in Tile.metal). The mask is the plane's
    // shadow: on the relief the cascades are sampled at the raised point
    // itself, as the vector ground's relief variants do.
    float shadowFactor = 1.0;
    if (kTileRasterRelief) {
        shadowFactor = sampleShadowFactor(shadow, shadowMap, in.worldPosition, float3(0.0));
    } else if (shadow.strength > 0.0) {
        constexpr sampler maskSampler(coord::pixel, filter::linear, address::clamp_to_edge);
        shadowFactor = float(groundShadowMask.sample(maskSampler, in.position.xy * kTileRasterGroundShadowMaskScale).r);
    }
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    color.rgb = applyGroundFog(color.rgb, in.worldPosition, groundFog);
    return color;
}

// MARK: - The relief's shadow

struct TileRasterReliefShadowVertexOut {
    float4 position [[position]];
};

/// The ground relief as a shadow caster (GroundReliefShadowCasterSubsystem):
/// the raster tiles' grid over a placement's square, raised by the terrain
/// as the ground is, seen from the light. Depth only, no fragment stage.
vertex TileRasterReliefShadowVertexOut tileRasterReliefShadowVertexShader(uint vertexID [[vertex_id]],
                                                                          constant float2* grid [[buffer(0)]],
                                                                          constant ShadowCasterMatrices& casters [[buffer(1)]],
                                                                          constant float4x4& modelMatrix [[buffer(3)]],
                                                                          constant GroundReliefUniform& relief [[buffer(9)]],
                                                                          texture2d<float> reliefHeights [[texture(0)]]) {
    float2 localPosition = grid[vertexID];
    float4 worldPosition = modelMatrix * float4(localPosition, 0.0, 1.0);
    worldPosition.z += groundReliefLift(localPosition, reliefHeights, relief);
    TileRasterReliefShadowVertexOut out;
    out.position = casters.lightProjectionView * worldPosition;
    return out;
}

// MARK: - The placement prepass's depth reset

/// One triangle over the whole screen at the far plane
/// (PlacementStencilRenderSubsystem): after the relief's marks are tested
/// against the ground's depth, that depth is put back to the cleared far
/// plane, so the ground passes meet the depth they met before the prepass
/// wrote any, their own and nothing else. Depth only, no fragment stage,
/// counter-clockwise like every triangle of the flat map.
vertex TileRasterReliefShadowVertexOut placementDepthResetVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    TileRasterReliefShadowVertexOut out;
    out.position = float4(positions[vertexID], 1.0, 1.0);
    return out;
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
    out.worldPosition = float3(0.0);
    out.sphereNormal = (globeFrame.sphereWorld * float4(unitDirection, 0.0)).xyz;
    return out;
}

struct TileRasterMorphVertexOut {
    float4 position [[position]];
    // The unroll's cut, as tileSphereMorphVertexShader's.
    float clipDistance [[clip_distance]] [1];
    float2 uv;
    float3 worldPosition;
    float3 sphereNormal;
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
    out.worldPosition = float3(0.0);
    out.sphereNormal = (globeFrame.sphereWorld * float4(unitDirection, 0.0)).xyz;
    return out;
}

fragment half4 tileRasterSphereFragmentShader(TileRasterFragmentIn in [[stage_in]],
                                              constant TileRasterSampling& sampling [[buffer(1)]],
                                              constant GlobeLight& globeLight [[buffer(kGlobeLightBufferIndex)]],
                                              texture2d<half> raster [[texture(0)]],
                                              sampler rasterSampler [[sampler(0)]]) {
    half4 color = tileRasterColor(in.uv, raster, rasterSampler, sampling);
    color.rgb = globeLitColor(color.rgb, in.sphereNormal, globeLight);
    return color;
}
