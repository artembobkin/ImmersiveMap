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

static inline float globeTransitionPanMercatorY(float panLatitude) {
    return getYMercNorm(panLatitude);
}

/// The flat x of a normalized world x, in the copy of the wrapped world
/// nearest the reference's: the seam of the wrap sits opposite the pan, and
/// a triangle whose vertices fold to opposite sides of it spans the whole
/// map. Vertices of one tile therefore unwrap around the tile's own centre
/// (the CPU does the same along a route, GeoSurfaceFrameMath.unwrapped);
/// a point with no neighbours passes itself as the reference and gets the
/// plain wrap.
static inline float globeTransitionFlatWorldX(float normalizedWorldX,
                                              float referenceNormalizedWorldX,
                                              constant Globe& globe,
                                              float mapSize) {
    float halfMapSize = mapSize * 0.5;
    float panOffset = globe.panX * halfMapSize - halfMapSize;
    float reference = wrap(referenceNormalizedWorldX * mapSize + panOffset, mapSize);
    float value = normalizedWorldX * mapSize + panOffset;
    return reference + wrap(value - reference, mapSize);
}

static inline float globeTransitionFlatWorldX(float normalizedWorldX,
                                              constant Globe& globe,
                                              float mapSize) {
    return globeTransitionFlatWorldX(normalizedWorldX, normalizedWorldX, globe, mapSize);
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
                                                      float panMercatorY,
                                                      float referenceNormalizedWorldX) {
    return float2(globeTransitionFlatWorldX(normalizedWorldX, referenceNormalizedWorldX, globe, mapSize),
                  globeTransitionFlatWorldY(mercatorY, panMercatorY, mapSize));
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
