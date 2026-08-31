// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeVisibility.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "GlobeTransitionProjection.h"

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

static inline float3 globeSphereWorldPosition(float lat,
                                              float lon,
                                              constant Globe& globe,
                                              float4x4 rotation) {
    float phi = lat - M_PI_2_F;
    float theta = lon + M_PI_F;

    float x = globe.radius * sin(phi) * sin(theta);
    float y = globe.radius * cos(phi);
    float z = globe.radius * sin(phi) * cos(theta);
    float4 rotatedPosition = float4(x, y, z, 1.0) * rotation;
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

/// The surface morph of one geographic point with every intermediate a
/// receiver of the projection may need: the two end positions, the unfurl
/// phase that mixes them, and the sphere normals for the lighting. The
/// visibility test, the label and footprint projections and the tile
/// geometry drawn on the sphere all take their positions from here, so the
/// morph geometry exists in exactly one place on the GPU (its CPU mirrors
/// live in GeoScreenProjectionMath, GeoSurfaceFrameMath and the atlas
/// footprint planner and must stay bit-compatible).
struct GlobeSurfaceProjection {
    float4 clip;
    float3 worldPosition;
    float3 sphereWorldPosition;
    float3 flatWorldPosition;
    /// The rotated unit sphere direction (pan applied): the surface normal
    /// the view-angle terms read.
    float3 normal;
    /// The earth-fixed unit sphere direction (before the pan rotation): what
    /// the sun direction is measured against.
    float3 earthNormal;
    float localTransition;
};

/// The same morph fed from GlobeFrameConstants: the pan rotation, the map
/// size and the Mercator pan are per-frame values, computed once on the CPU
/// (GlobeFrameConstantsUniform) instead of once per vertex. `pureSphere` is
/// meant to be a function constant: when true (transition 0 by the caller's
/// gate, GlobeSphereVertexPath), the flat morph target, the unfurl phase and
/// the mix fold away and the surface is the sphere itself.
static inline GlobeSurfaceProjection globeProjectLatLonDetailed(float lat,
                                                                float lon,
                                                                constant Camera& camera,
                                                                constant Globe& globe,
                                                                constant GlobeFrameConstants& frame,
                                                                float referenceNormalizedWorldX,
                                                                bool pureSphere) {
    float3 sphereWorldPosition = globeSphereWorldPosition(lat, lon, globe, frame.rotation);
    float3 flatWorldPosition;
    float localTransition;
    float3 worldPosition;
    if (pureSphere) {
        flatWorldPosition = float3(0.0);
        localTransition = 0.0;
        worldPosition = sphereWorldPosition;
    } else {
        flatWorldPosition = globeFlatWorldPosition(lat, lon, globe, frame.mapSize,
                                                   frame.panMercatorY, referenceNormalizedWorldX);
        // The same unfurl wave as the self-contained overload below.
        float frontDot = (sphereWorldPosition.z + globe.radius) / max(globe.radius, 1e-6);
        localTransition = globeTransitionLocalPhase(globe.transition, frontDot);
        worldPosition = mix(sphereWorldPosition, flatWorldPosition, localTransition);
    }

    float phi = lat - M_PI_2_F;
    float theta = lon + M_PI_F;
    float3 earthDirection = float3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta));

    GlobeSurfaceProjection result;
    result.worldPosition = worldPosition;
    result.clip = camera.matrix * float4(worldPosition, 1.0);
    result.sphereWorldPosition = sphereWorldPosition;
    result.flatWorldPosition = flatWorldPosition;
    result.normal = normalize((float4(earthDirection, 0.0) * frame.rotation).xyz);
    result.earthNormal = normalize(earthDirection);
    result.localTransition = localTransition;
    return result;
}

static inline GlobeSurfaceProjection globeProjectLatLonDetailed(float lat,
                                                                float lon,
                                                                constant Camera& camera,
                                                                constant Globe& globe,
                                                                float referenceNormalizedWorldX) {
    float panLatitude = globeVisibilityPanLatitude(globe);
    float panLongitude = globeVisibilityPanLongitude(globe);
    float mapSize = globeVisibilityMapSize(globe, panLatitude);
    float4x4 rotation = globeVisibilityRotationMatrix(panLatitude, panLongitude);
    float panMercatorY = globeTransitionPanMercatorY(panLatitude);

    float3 sphereWorldPosition = globeSphereWorldPosition(lat, lon, globe, rotation);
    float3 flatWorldPosition = globeFlatWorldPosition(lat, lon, globe, mapSize, panMercatorY,
                                                      referenceNormalizedWorldX);
    // The same unfurl wave as in the surface vertex shader: label and
    // footprint projections must sit on the actual morph geometry.
    float frontDot = (sphereWorldPosition.z + globe.radius) / max(globe.radius, 1e-6);
    float localTransition = globeTransitionLocalPhase(globe.transition, frontDot);
    float3 worldPosition = mix(sphereWorldPosition, flatWorldPosition, localTransition);

    // The unrotated unit direction is the sphere point over its radius; the
    // rotated one is what the surface grid interpolates as its normal.
    float phi = lat - M_PI_2_F;
    float theta = lon + M_PI_F;
    float3 earthDirection = float3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta));

    GlobeSurfaceProjection result;
    result.worldPosition = worldPosition;
    result.clip = camera.matrix * float4(worldPosition, 1.0);
    result.sphereWorldPosition = sphereWorldPosition;
    result.flatWorldPosition = flatWorldPosition;
    result.normal = normalize((float4(earthDirection, 0.0) * rotation).xyz);
    result.earthNormal = normalize(earthDirection);
    result.localTransition = localTransition;
    return result;
}

/// A point on its own: its flat x unwraps around itself, the plain wrap.
static inline GlobeSurfaceProjection globeProjectLatLonDetailed(float lat,
                                                                float lon,
                                                                constant Camera& camera,
                                                                constant Globe& globe) {
    return globeProjectLatLonDetailed(lat, lon, camera, globe, (lon + M_PI_F) / (2.0 * M_PI_F));
}

static inline GlobeVisibilityProjectionResult globeProjectLatLon(float lat,
                                                                 float lon,
                                                                 constant Camera& camera,
                                                                 constant Globe& globe) {
    GlobeSurfaceProjection projection = globeProjectLatLonDetailed(lat, lon, camera, globe);
    GlobeVisibilityProjectionResult result;
    result.worldPosition = projection.worldPosition;
    result.clip = projection.clip;
    return result;
}

#endif
