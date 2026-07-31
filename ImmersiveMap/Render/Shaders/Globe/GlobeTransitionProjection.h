// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeTransitionProjection.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"
#include "../Shared/GeoMath.h"

#ifndef GLOBE_TRANSITION_PROJECTION
#define GLOBE_TRANSITION_PROJECTION

static inline float globeTransitionPanLatitude(constant Globe& globe) {
    float maxLatitude = 2.0 * atan(exp(M_PI_F)) - M_PI_2_F;
    return globe.panY * maxLatitude;
}

static inline float globeTransitionPanLongitude(constant Globe& globe) {
    return globe.panX * M_PI_F;
}

static inline float globeTransitionMapSize(constant Globe& globe,
                                           float panLatitude) {
    float distortion = cos(panLatitude);
    float mapSizeScale = mix(distortion, 1.0, globe.transition);
    return 2.0 * M_PI_F * globe.radius * mapSizeScale;
}

/// The wave of the sphere unfurling into a plane. With a uniform lerp the far
/// corners of the mercator sheet, which have to travel the farthest, start
/// immediately and "settle" first. Here a vertex's local phase lags the global
/// one proportionally to its angular distance from the view center (`frontDot`
/// is the cosine of that angle): the near area finishes unfurling first, the
/// wave rolls outward, the corners settle last. The extremes match the uniform
/// lerp: t = 0 - sphere, t = 1 - plane. CPU mirror -
/// `GlobeFootprintProjectionConstants.transitionLocalPhase`.
static inline float globeTransitionLocalPhase(float transition, float frontDot) {
    const float spread = 0.6;
    float lagWeight = acos(clamp(frontDot, -1.0, 1.0)) / M_PI_F;
    return clamp((transition - lagWeight * spread) / (1.0 - spread), 0.0, 1.0);
}

static inline float globeTransitionPanMercatorY(float panLatitude) {
    return getYMercNorm(panLatitude);
}

static inline float globeTransitionFlatWorldX(float normalizedWorldX,
                                              constant Globe& globe,
                                              float mapSize) {
    float halfMapSize = mapSize * 0.5;
    return wrap(normalizedWorldX * mapSize - halfMapSize + globe.panX * halfMapSize, mapSize);
}

static inline float globeTransitionFlatWorldY(float mercatorY,
                                              float panMercatorY,
                                              float mapSize) {
    float halfMapSize = mapSize * 0.5;
    return (mercatorY - panMercatorY) * halfMapSize;
}

static inline float2 globeTransitionFlatWorldPosition(float normalizedWorldX,
                                                      float mercatorY,
                                                      constant Globe& globe,
                                                      float mapSize,
                                                      float panMercatorY) {
    return float2(globeTransitionFlatWorldX(normalizedWorldX, globe, mapSize),
                  globeTransitionFlatWorldY(mercatorY, panMercatorY, mapSize));
}

#endif
