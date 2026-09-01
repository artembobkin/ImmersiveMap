// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeUnroll.h
//  ImmersiveMap
//
//  The sphere-to-plane unroll. The morph never mixes positions through the
//  planet's interior: the surface lives on a sphere of radius 1 / curvature
//  tangent to the view centre, with curvature = (1 - transition) / radius.
//  Every point keeps its distance along the surface from the view centre
//  (blended from the great-circle arc toward the flat Mercator distance)
//  and its azimuth (blended likewise), and the growing sphere flattens the
//  cap into the plane. At transition 0 the surface is exactly the sphere,
//  at 1 exactly the flat Mercator world, and in between it stays a
//  single-valued convex cap: nothing ever passes behind or through the
//  planet, so the unroll needs no occlusion clip at all. The CPU mirror is
//  GlobeUnrollMath.swift and must stay bit-compatible.
//

#include <metal_stdlib>
using namespace metal;

#ifndef GLOBE_UNROLL
#define GLOBE_UNROLL

static inline float3 globeUnrollWorldPosition(float3 sphereWorldPosition,
                                              float2 flatWorldPosition,
                                              float transition,
                                              float radius) {
    float curvature = (1.0 - transition) / max(radius, 1e-6);
    if (curvature <= 1e-9) {
        return float3(flatWorldPosition, 0.0);
    }
    float3 fromCenter = sphereWorldPosition - float3(0.0, 0.0, -radius);
    float cosTheta = clamp(fromCenter.z / max(radius, 1e-6), -1.0, 1.0);
    float arcSphere = radius * acos(cosTheta);
    float2 dirSphere = fromCenter.xy;
    float dirSphereLength = length(dirSphere);
    float arcFlat = length(flatWorldPosition);
    float2 azimuthSphere = dirSphereLength > 1e-6 ? dirSphere / dirSphereLength
        : (arcFlat > 1e-6 ? flatWorldPosition / arcFlat : float2(0.0, 1.0));
    float2 azimuthFlat = arcFlat > 1e-6 ? flatWorldPosition / arcFlat : azimuthSphere;
    float2 azimuthMix = mix(azimuthSphere, azimuthFlat, transition);
    float azimuthLength = length(azimuthMix);
    float2 azimuth = azimuthLength > 1e-6 ? azimuthMix / azimuthLength : azimuthSphere;
    float arc = mix(arcSphere, arcFlat, transition);
    float angle = arc * curvature;
    float rho = sin(angle) / curvature;
    float sag = (cos(angle) - 1.0) / curvature;
    return float3(azimuth * rho, sag);
}

#endif
