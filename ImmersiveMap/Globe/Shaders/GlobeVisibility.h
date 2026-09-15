// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeVisibility.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "GlobeTransitionProjection.h"
#include "GlobeUnroll.h"

#ifndef GLOBE_VISIBILITY
#define GLOBE_VISIBILITY

struct GlobeVisibilityProjectionResult {
    float4 clip;
    float3 worldPosition;
};

static inline float globeVisibilityPanLatitude(constant Globe& globe) {
    return globeTransitionPanLatitude(globe);
}

static inline float globeVisibilityPanLongitude(constant Globe& globe) {
    return globeTransitionPanLongitude(globe);
}

static inline float globeVisibilityMapSize(constant Globe& globe,
                                           float panLatitude) {
    return globeTransitionMapSize(globe, panLatitude);
}

static inline float4x4 globeVisibilityRotationMatrix(float panLatitude,
                                                     float panLongitude) {
    float cx = cos(-panLatitude);
    float sx = sin(-panLatitude);
    float cy = cos(-panLongitude);
    float sy = sin(-panLongitude);

    return float4x4(
        float4(cy,        0,         -sy,       0),
        float4(sy * sx,   cx,        cy * sx,   0),
        float4(sy * cx,  -sx,        cy * cx,   0),
        float4(0,         0,          0,        1)
    );
}

/// The unit earth-fixed direction of a geographic coordinate: what the
/// composed sphere matrices multiply.
static inline float3 globeSphereUnitDirection(float lat, float lon) {
    float phi = lat - M_PI_2_F;
    float theta = lon + M_PI_F;
    return float3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta));
}

static inline float3 globeSphereWorldPosition(float lat,
                                              float lon,
                                              constant Globe& globe,
                                              float4x4 rotation) {
    float3 unitDirection = globeSphereUnitDirection(lat, lon);
    float4 rotatedPosition = float4(unitDirection * globe.radius, 1.0) * rotation;
    return (rotatedPosition - float4(0.0, 0.0, globe.radius, 0.0)).xyz;
}

/// `referenceNormalizedWorldX` is the world x the flat position unwraps
/// around (a tile's centre for its vertices, see globeTransitionFlatWorldX).
static inline float3 globeFlatWorldPosition(float lat,
                                            float lon,
                                            constant Globe& globe,
                                            float mapSize,
                                            float panMercatorY,
                                            float referenceNormalizedWorldX) {
    float normalizedWorldX = (lon + M_PI_F) / (2.0 * M_PI_F);
    float mercatorY = getYMercNorm(lat);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(normalizedWorldX,
                                                                mercatorY,
                                                                globe,
                                                                mapSize,
                                                                panMercatorY,
                                                                referenceNormalizedWorldX);
    return float3(flatWorldPosition, 0.0);
}

/// The unrolled surface position of one geographic point, self-contained:
/// recomputes the per-frame pan values locally, which is what the label
/// placement kernel wants for its handful of points. The hot tile vertex
/// stages take the same values precomputed in GlobeFrameConstants instead.
/// CPU mirrors: GeoScreenProjectionMath and GeoSurfaceFrameMath, which must
/// stay bit-compatible with this construction.
static inline float3 globeUnrollProjectWorldPosition(float lat,
                                                     float lon,
                                                     constant Globe& globe,
                                                     float referenceNormalizedWorldX) {
    float panLatitude = globeVisibilityPanLatitude(globe);
    float panLongitude = globeVisibilityPanLongitude(globe);
    float4x4 rotation = globeVisibilityRotationMatrix(panLatitude, panLongitude);
    float3 sphereWorldPosition = globeSphereWorldPosition(lat, lon, globe, rotation);
    if (globe.transition <= 0.0) {
        return sphereWorldPosition;
    }
    float mapSize = globeVisibilityMapSize(globe, panLatitude);
    float panMercatorY = globeTransitionPanMercatorY(panLatitude);
    float3 flatWorldPosition = globeFlatWorldPosition(lat, lon, globe, mapSize, panMercatorY,
                                                      referenceNormalizedWorldX);
    return globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition.xy,
                                    globe.transition, globe.radius);
}

static inline GlobeVisibilityProjectionResult globeProjectLatLon(float lat,
                                                                 float lon,
                                                                 constant Camera& camera,
                                                                 constant Globe& globe) {
    float3 worldPosition = globeUnrollProjectWorldPosition(lat, lon, globe,
                                                           (lon + M_PI_F) / (2.0 * M_PI_F));
    GlobeVisibilityProjectionResult result;
    result.worldPosition = worldPosition;
    result.clip = camera.matrix * float4(worldPosition, 1.0);
    return result;
}

#endif
