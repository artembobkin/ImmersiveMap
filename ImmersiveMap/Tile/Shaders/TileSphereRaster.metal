// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"
#include "../../Globe/Shaders/GlobeTileProjection.h"

// A rasterized tile on the sphere: the picture TileRasterizer rendered for
// the plane, the same texture, laid over the tile's extent on the globe.
// The plane draws it as one quad (TileRaster.metal). The sphere needs the
// quad's chords to follow the curvature, so the vertex stage builds a grid
// over the tile's square from the vertex id, as many cells a side as the
// parser's own split of the ground gives a tile of that zoom
// (GroundGeometrySubdivider), and sends every grid point through the
// projection the vector ground uses (TileSphere.metal): the resting sphere
// through the frame's sphere-to-clip matrix, the unfurl through the unroll
// with its one clip distance. Kept out of TileSphere.metal, which is pinned
// to sample no texture.
//
// The alpha is the picture's share of the pixel in the raster zone
// (RasterZone.swift), by the distance from the camera to the surface point,
// exactly as on the plane. The depth is a rank of the ground's band stated
// by the draw, written from the vertex stage like the sphere's other ranks.

constant float kTileSphereRasterExtent = 4096.0;

// Mirrors GlobeSurfaceTile in TileSphere.metal (GlobeSurfaceTileUniform.swift).
struct TileSphereRasterTile {
    float2 uvOrigin;
    float uvScale;
    float referenceWorldX;
};

// Mirrors TileSphereRasterGridUniform (TileSphereRasterDrawer.swift).
struct TileSphereRasterGrid {
    // Cells a side of the grid.
    uint cells;
    // The picture's rank depth in NDC.
    float rankDepth;
};

// Mirrors TileRasterZoneUniform (TileRasterDrawer.swift).
struct TileSphereRasterZone {
    // xyz the camera in the render world, w the zone's start distance.
    float4 eyeAndStart;
    // x the zone's end distance.
    float4 endAndRankDepth;
};

struct TileSphereRasterVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 worldPosition;
};

struct TileSphereRasterMorphVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 worldPosition;
    float clipDistance [[clip_distance]] [1];
};

// The grid point of a vertex id, as the picture's uv: u east, v from the
// tile's north edge, which is also the tile-local uv of the projection.
// Six vertices a cell, two triangles, counter-clockwise in render space
// (y up) like every tile triangle: the sphere leaves the far hemisphere to
// back-face culling.
static inline float2 tileSphereRasterGridUv(uint vertexID, uint cells) {
    const float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0)
    };
    uint cell = vertexID / 6u;
    float2 cellOrigin = float2(float(cell % cells), float(cell / cells));
    // Render-space position in cells, y up.
    float2 position = (cellOrigin + corners[vertexID % 6u]) / float(cells);
    return float2(position.x, 1.0 - position.y);
}

vertex TileSphereRasterVertexOut tileSphereRasterPureVertexShader(uint vertexID [[vertex_id]],
                                                                  constant TileSphereRasterTile& surfaceTile [[buffer(9)]],
                                                                  constant GlobeFrameConstants& globeFrame [[buffer(10)]],
                                                                  constant TileSphereRasterGrid& grid [[buffer(12)]]) {
    float2 uv = tileSphereRasterGridUv(vertexID, grid.cells);
    float3 unitDirection = globeWorldUVUnitDirection(surfaceTile.uvOrigin + uv * surfaceTile.uvScale);
    TileSphereRasterVertexOut out;
    out.position = globeFrame.sphereClip * float4(unitDirection, 1.0);
    out.position.z = grid.rankDepth * out.position.w;
    out.uv = uv;
    out.worldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    return out;
}

vertex TileSphereRasterMorphVertexOut tileSphereRasterMorphVertexShader(uint vertexID [[vertex_id]],
                                                                        constant Camera& camera [[buffer(1)]],
                                                                        constant Globe& globe [[buffer(8)]],
                                                                        constant TileSphereRasterTile& surfaceTile [[buffer(9)]],
                                                                        constant GlobeFrameConstants& globeFrame [[buffer(10)]],
                                                                        constant TileSphereRasterGrid& grid [[buffer(12)]]) {
    float2 uv = tileSphereRasterGridUv(vertexID, grid.cells);
    float2 worldUv = surfaceTile.uvOrigin + uv * surfaceTile.uvScale;
    float3 unitDirection = globeWorldUVUnitDirection(worldUv);
    float3 sphereWorldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    float mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                                globeFrame.mapSize, globeFrame.panMercatorY,
                                                                surfaceTile.referenceWorldX);
    float3 worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                    globe.transition, globe.radius);
    TileSphereRasterMorphVertexOut out;
    out.position = camera.matrix * float4(worldPosition, 1.0);
    out.position.z = grid.rankDepth * out.position.w;
    out.uv = uv;
    out.worldPosition = worldPosition;
    // The unroll's cut, as for the vector ground.
    out.clipDistance[0] = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                                  globe.transition, globe.radius);
    return out;
}

struct TileSphereRasterFragmentIn {
    float4 position [[position]];
    float2 uv;
    float3 worldPosition;
};

fragment half4 tileSphereRasterFragmentShader(TileSphereRasterFragmentIn in [[stage_in]],
                                              constant TileSphereRasterZone& zone [[buffer(4)]],
                                              texture2d<half> picture [[texture(0)]]) {
    // Trilinear with anisotropy: a tile at the limb is seen edge on.
    constexpr sampler pictureSampler(coord::normalized, filter::linear, mip_filter::linear,
                                     max_anisotropy(8), address::clamp_to_edge);
    half4 color = picture.sample(pictureSampler, in.uv);
    float distance = length(in.worldPosition - zone.eyeAndStart.xyz);
    float start = zone.eyeAndStart.w;
    float end = zone.endAndRankDepth.x;
    float share = end > start ? smoothstep(start, end, distance) : step(start, distance);
    return half4(color.rgb, half(share));
}
