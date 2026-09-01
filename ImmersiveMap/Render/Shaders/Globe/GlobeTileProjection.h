// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeTileProjection.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "GlobeVisibility.h"

#ifndef GLOBE_TILE_PROJECTION
#define GLOBE_TILE_PROJECTION

/// The geographic coordinate of a tile-local uv (x east, uv.y = 0 at the
/// tile's NORTH edge, Mercator-linear: the axis the raw MVT bytes and the
/// mercator tile rows use). Values outside 0..1 are allowed and land beyond
/// the tile, which the stitching margins of line geometry rely on.
/// The geographic coordinate of a world uv (x east in turns, y the Mercator
/// row, both 0..1 across the world): the form the per-draw uniforms carry so
/// no per-vertex pow(2, z) is needed.
static inline float2 globeWorldUVLatLon(float2 worldUv) {
    float latitudeAtUv = atan(sinh(M_PI_F * (1.0 - 2.0 * worldUv.y)));
    float longitudeAtUv = worldUv.x * (2.0 * M_PI_F) - M_PI_F;
    return float2(latitudeAtUv, longitudeAtUv);
}

static inline float2 globeTileUVLatLon(float2 localUv, int3 tile) {
    float zPow = pow(2.0, tile.z);
    float size = 1.0 / zPow;
    float vertexUvX = localUv.x / zPow + size * float(tile.x);
    float mercatorV = (float(tile.y) + localUv.y) / zPow;
    float latitudeAtUv = atan(sinh(M_PI_F * (1.0 - 2.0 * mercatorV)));
    float longitudeAtUv = vertexUvX * (2.0 * M_PI_F) - M_PI_F;
    return float2(latitudeAtUv, longitudeAtUv);
}

/// The normalized world x of the tile's centre: what every vertex of the
/// tile unwraps its flat morph target around, so a tile touching the seam
/// of the wrap (opposite the pan) stays in one piece instead of tearing
/// into a band across the whole map.
static inline float globeTileReferenceWorldX(int3 tile) {
    return (float(tile.x) + 0.5) / pow(2.0, tile.z);
}

static inline GlobeVisibilityProjectionResult globeProjectTileUV(float2 localUv,
                                                                 int3 tile,
                                                                 constant Camera& camera,
                                                                 constant Globe& globe) {
    float2 latLon = globeTileUVLatLon(localUv, tile);
    GlobeSurfaceProjection projection = globeProjectLatLonDetailed(latLon.x, latLon.y, camera, globe,
                                                                   globeTileReferenceWorldX(tile));
    GlobeVisibilityProjectionResult result;
    result.worldPosition = projection.worldPosition;
    result.clip = projection.clip;
    return result;
}

/// The full surface projection of a tile-local uv, for geometry drawn on
/// the sphere (TileSphere.metal).
static inline GlobeSurfaceProjection globeProjectTileUVDetailed(float2 localUv,
                                                                int3 tile,
                                                                constant Camera& camera,
                                                                constant Globe& globe) {
    float2 latLon = globeTileUVLatLon(localUv, tile);
    return globeProjectLatLonDetailed(latLon.x, latLon.y, camera, globe, globeTileReferenceWorldX(tile));
}

/// The frame-constants variant of the projection above; `pureSphere` is a
/// function constant of the calling vertex stage (see GlobeVisibility.h).
static inline GlobeSurfaceProjection globeProjectTileUVDetailed(float2 localUv,
                                                                int3 tile,
                                                                constant Camera& camera,
                                                                constant Globe& globe,
                                                                constant GlobeFrameConstants& frame,
                                                                bool pureSphere) {
    float2 latLon = globeTileUVLatLon(localUv, tile);
    return globeProjectLatLonDetailed(latLon.x, latLon.y, camera, globe, frame,
                                      globeTileReferenceWorldX(tile), pureSphere);
}

static inline GlobeVisibilityProjectionResult globeProjectLatLonFromTile(float lat,
                                                                         float lon,
                                                                         constant Camera& camera,
                                                                         constant Globe& globe) {
    return globeProjectLatLon(lat, lon, camera, globe);
}

#endif
