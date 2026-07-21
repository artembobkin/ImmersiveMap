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

static inline float3 globeFlatWorldPosition(float lat,
                                            float lon,
                                            constant Globe& globe,
                                            float mapSize,
                                            float panMercatorY) {
    float normalizedWorldX = (lon + M_PI_F) / (2.0 * M_PI_F);
    float mercatorY = getYMercNorm(lat);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(normalizedWorldX,
                                                                mercatorY,
                                                                globe,
                                                                mapSize,
                                                                panMercatorY);
    return float3(flatWorldPosition, 0.0);
}

static inline GlobeVisibilityProjectionResult globeProjectLatLon(float lat,
                                                                 float lon,
                                                                 constant Camera& camera,
                                                                 constant Globe& globe) {
    float panLatitude = globeVisibilityPanLatitude(globe);
    float panLongitude = globeVisibilityPanLongitude(globe);
    float mapSize = globeVisibilityMapSize(globe, panLatitude);
    float4x4 rotation = globeVisibilityRotationMatrix(panLatitude, panLongitude);
    float panMercatorY = globeTransitionPanMercatorY(panLatitude);

    float3 sphereWorldPosition = globeSphereWorldPosition(lat, lon, globe, rotation);
    float3 flatWorldPosition = globeFlatWorldPosition(lat, lon, globe, mapSize, panMercatorY);
    float3 worldPosition = mix(sphereWorldPosition, flatWorldPosition, globe.transition);

    GlobeVisibilityProjectionResult result;
    result.worldPosition = worldPosition;
    result.clip = camera.matrix * float4(worldPosition, 1.0);
    return result;
}

static inline float globeVisibilityHorizonThreshold(constant Globe& globe) {
    // Порог ослабляется непрерывно по всему морфу и в масштабе геометрии.
    // Прежний mix(R², -1e6, smoothstep(0.8, 0.95, t)) из-за огромного -1e6
    // проваливался ниже минимально возможного dot уже при fade ≈ 0.0003 -
    // фактически ступенька ровно на t = 0.8: загоризонтная геометрия
    // вспыхивала одним кадром. -4R² ниже минимума dot любой точки сферы,
    // так что к t = 0.95 каллинг полностью выключен, как и раньше, но путь
    // к этому - плавный.
    float horizonFade = smoothstep(0.0, 0.95, globe.transition);
    float radiusSquared = globe.radius * globe.radius;
    return mix(radiusSquared, -4.0 * radiusSquared, horizonFade);
}

static inline bool globePointPassesVisibility(float3 worldPosition,
                                              constant Camera& camera,
                                              constant Globe& globe) {
    float3 globeCenter = float3(0.0, 0.0, -globe.radius);
    float3 toCamera = camera.eye - globeCenter;
    if (length(toCamera) <= 0.0 || globe.transition >= 0.95) {
        return true;
    }
    float dotToCamera = dot(worldPosition - globeCenter, toCamera);
    return dotToCamera >= globeVisibilityHorizonThreshold(globe);
}

#endif
