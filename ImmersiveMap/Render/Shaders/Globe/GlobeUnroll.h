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
//  A sphere cannot unroll without a cut. The cut is the cap around the
//  point opposite the view centre (the tear is dynamic, it follows the
//  view): inside it the two charts comb the polar fan apart and the blend
//  genuinely folds, so the morph vertex stage clips everything past
//  kGlobeUnrollCutCosine as its fifth clip distance. Outside the cut the
//  blend's residual folds paint no closer than half a radius from the view
//  centre, far off-screen at the zooms the morph runs at; both facts are
//  swept numerically by GlobeUnrollFoldTests. The CPU mirror is
//  GlobeUnrollMath.swift and must stay bit-compatible.
//

#include <metal_stdlib>
using namespace metal;

#ifndef GLOBE_UNROLL
#define GLOBE_UNROLL

/// cos(150 degrees): the unroll's cut. A vertex whose sphere direction lies
/// more than 150 degrees of arc from the view centre is clipped while the
/// sphere unfurls (visible iff cos(theta) exceeds this). Mirrored by
/// GlobeUnrollMath.cutCosine.
constant float kGlobeUnrollCutCosine = -0.8660254;

static inline float3 globeUnrollWorldPosition(float3 sphereWorldPosition,
                                              float2 flatWorldPosition,
                                              float transition,
                                              float radius) {
    float curvature = (1.0 - transition) / max(radius, 1e-6);
    if (curvature <= 1e-9) {
        return float3(flatWorldPosition, 0.0);
    }
    // The azimuthal-equidistant image: arc from the view centre times the
    // departure bearing. Wrapping it back at curvature 1/R is the identity.
    float3 fromCenter = sphereWorldPosition - float3(0.0, 0.0, -radius);
    float cosTheta = clamp(fromCenter.z / max(radius, 1e-6), -1.0, 1.0);
    float arcSphere = radius * acos(cosTheta);
    float2 dirSphere = fromCenter.xy;
    float dirSphereLength = length(dirSphere);
    float2 azimuthalEquidistant = dirSphereLength > 1e-6
        ? dirSphere * (arcSphere / dirSphereLength)
        : float2(0.0, 0.0);
    // The straight chart line between the two flat images of the point.
    float2 chartPoint = mix(azimuthalEquidistant, flatWorldPosition, transition);
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
