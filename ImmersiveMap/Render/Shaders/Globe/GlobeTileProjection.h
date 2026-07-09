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

static inline GlobeVisibilityProjectionResult globeProjectTileUV(float2 localUv,
                                                                 int3 tile,
                                                                 constant Camera& camera,
                                                                 constant Globe& globe) {
    float zPow = pow(2.0, tile.z);
    float size = 1.0 / zPow;
    float vertexUvX = localUv.x / zPow + size * float(tile.x);
    float mercatorV = (float(tile.y) + localUv.y) / zPow;
    float latitudeAtUv = atan(sinh(M_PI_F * (1.0 - 2.0 * mercatorV)));
    float longitudeAtUv = vertexUvX * (2.0 * M_PI_F) - M_PI_F;
    return globeProjectLatLon(latitudeAtUv, longitudeAtUv, camera, globe);
}

static inline GlobeVisibilityProjectionResult globeProjectLatLonFromTile(float lat,
                                                                         float lon,
                                                                         constant Camera& camera,
                                                                         constant Globe& globe) {
    return globeProjectLatLon(lat, lon, camera, globe);
}

#endif
