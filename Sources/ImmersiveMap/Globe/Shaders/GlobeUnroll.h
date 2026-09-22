// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeUnroll.h
//  ImmersiveMap
//
//  The sphere-to-plane unroll. The morph never mixes positions through the
//  planet's interior: the surface lives on a sphere of radius 1 / curvature
//  tangent to the view centre, with curvature = (1 - transition) / radius,
//  and every point travels a straight line in the chart. A point's two flat
//  images are its azimuthal-equidistant projection about the view centre
//  (arc times bearing: wrapping that chart back onto the sphere of radius R
//  is the identity) and its Mercator position; the morph lerps between the
//  two IN THE PLANE and wraps the blended point onto the growing sphere.
//  At transition 0 the surface is exactly the sphere, at 1 exactly the flat
//  Mercator world, and in between neighbouring points travel continuous
//  straight chart lines: no direction snapping, so triangles do not fold
//  into slivers.
//
//  A sphere cannot unroll without tearing, and some content genuinely has
//  to travel: whatever lies past a pole or past the point opposite the view
//  has a Mercator home half a map sideways, and its chart line lawfully
//  crosses the visible region. The cut therefore follows the JOURNEY, not a
//  fixed cap: a vertex is clipped while its remaining travel
//  (1 - t) * |mercator - azimuthal| exceeds kGlobeUnrollCutTravel of a
//  radius, and appears only when it is nearly home. At transition 0 the
//  clipped set is exactly the content whose two charts disagree, which is
//  never visible on the resting sphere (near the view the charts agree);
//  by transition 1 everything has arrived and nothing is clipped, so the
//  cut opens and closes without a pop. GlobeUnrollFoldTests sweeps the
//  production morph and pins that nothing folded and no long-haul traveller
//  survives the clip anywhere near the view. The CPU mirror is
//  GlobeUnrollMath.swift and must stay bit-compatible.
//

#include <metal_stdlib>
using namespace metal;

#ifndef GLOBE_UNROLL
#define GLOBE_UNROLL

/// The unroll's cut, as a fraction of the planet radius: a vertex is
/// clipped while its remaining chart travel exceeds this. Mirrored by
/// GlobeUnrollMath.cutTravelFraction.
constant float kGlobeUnrollCutTravel = 0.25;

/// The azimuthal-equidistant image of a sphere position about the view
/// centre: arc times departure bearing. Wrapping it back onto the sphere of
/// radius R is the identity.
static inline float2 globeUnrollChartAE(float3 sphereWorldPosition, float radius) {
    float3 fromCenter = sphereWorldPosition - float3(0.0, 0.0, -radius);
    float cosTheta = clamp(fromCenter.z / max(radius, 1e-6), -1.0, 1.0);
    float arcSphere = radius * acos(cosTheta);
    float2 dirSphere = fromCenter.xy;
    float dirSphereLength = length(dirSphere);
    return dirSphereLength > 1e-6 ? dirSphere * (arcSphere / dirSphereLength) : float2(0.0, 0.0);
}

/// The cut clearance the morph vertex stage hands to the rasterizer:
/// positive once the vertex's remaining chart travel is short enough to
/// show. Normalized by the radius so the clip distances stay of order one.
static inline float globeUnrollCutClearance(float3 sphereWorldPosition,
                                            float2 flatWorldPosition,
                                            float transition,
                                            float radius) {
    float2 chartAE = globeUnrollChartAE(sphereWorldPosition, radius);
    float remaining = (1.0 - transition) * length(flatWorldPosition - chartAE);
    return kGlobeUnrollCutTravel - remaining / max(radius, 1e-6);
}

static inline float3 globeUnrollWorldPosition(float3 sphereWorldPosition,
                                              float2 flatWorldPosition,
                                              float transition,
                                              float radius) {
    float curvature = (1.0 - transition) / max(radius, 1e-6);
    if (curvature <= 1e-9) {
        return float3(flatWorldPosition, 0.0);
    }
    // The straight chart line between the two flat images of the point.
    float2 chartPoint = mix(globeUnrollChartAE(sphereWorldPosition, radius), flatWorldPosition, transition);
    float arc = length(chartPoint);
    if (arc <= 1e-6) {
        return float3(chartPoint, 0.0);
    }
    float2 azimuth = chartPoint / arc;
    float angle = arc * curvature;
    float rho = sin(angle) / curvature;
    float sag = (cos(angle) - 1.0) / curvature;
    return float3(azimuth * rho, sag);
}

#endif
