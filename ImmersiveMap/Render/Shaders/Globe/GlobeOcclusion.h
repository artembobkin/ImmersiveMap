// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  GlobeOcclusion.h
//  ImmersiveMap
//
//  The sphere as an analytic occluder for the geometry drawn on it. The
//  globe surface does not depth-test (its extent is the slot clip distances
//  and back-face culling), and while the sphere unfurls into the plane the
//  far side of the planet is placed and morphs along chords through the
//  planet's interior: a chord can turn front-facing while it is still
//  behind the near side, and back-face culling cannot tell. So every vertex
//  asks the one question the depth test used to answer: does the segment
//  from the eye to the vertex enter the planet before it gets there? Routes
//  ask the same question per fragment (routeGlobeClearance in Route.metal);
//  the surface asks it per vertex and hands the answer to the rasterizer as
//  a clip distance. The CPU mirror is GlobeOcclusionMath.swift.
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"

#ifndef GLOBE_OCCLUSION
#define GLOBE_OCCLUSION

/// The sphere is shrunk by this fraction of its radius before the test. The
/// vertices of the near side sit exactly on the sphere at t = 0, and the
/// chords between them sag below it, so without a margin the clearance of
/// the whole visible surface would be zero plus float noise, and half of it
/// would be clipped at random. Well above the float error of a position of
/// magnitude R, and far below any chord the parser's subdivision leaves.
constant float kGlobeOcclusionRadiusMargin = 1.0e-4;

/// How far the segment from the eye to `position` passes clear of the
/// sphere, in world units: positive when the eye sees the point (it lies in
/// front of the planet, or the segment misses the planet altogether),
/// negative when the planet stands in the way. Continuous everywhere: the
/// three branches meet where the closest approach of the segment to the
/// centre lands on the eye or on the point. At t = 0 the sign agrees with
/// the horizon predicate for points on the sphere; at t = 1 every point is
/// on the plane z = 0 and no segment from an eye above the plane enters
/// the sphere below it, so nothing is clipped.
static inline float globeOcclusionClearance(float3 position,
                                            constant Camera& camera,
                                            constant Globe& globe) {
    float radius = max(globe.radius, 1e-6) * (1.0 - kGlobeOcclusionRadiusMargin);
    float3 globeCenter = float3(0.0, 0.0, -globe.radius);
    float3 centerToEye = camera.eye - globeCenter;
    float3 toPosition = position - camera.eye;
    float lengthSquared = dot(toPosition, toPosition);
    if (lengthSquared <= 0.0) {
        return length(centerToEye) - radius;
    }
    float closestFraction = -dot(centerToEye, toPosition) / lengthSquared;
    if (closestFraction <= 0.0) {
        // The nearest approach lies behind the eye: the planet is behind the
        // camera, which is always outside it.
        return length(centerToEye) - radius;
    }
    if (closestFraction >= 1.0) {
        // The nearest approach lies beyond the point: the point is on the
        // near side of the planet, clear of it unless it is inside.
        return length(position - globeCenter) - radius;
    }
    float3 closest = centerToEye + toPosition * closestFraction;
    return length(closest) - radius;
}

#endif
