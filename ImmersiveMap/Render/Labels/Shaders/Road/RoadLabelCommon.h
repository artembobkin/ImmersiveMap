// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

#ifndef ROAD_LABEL_COMMON
#define ROAD_LABEL_COMMON

struct RoadPathRange {
    uint start;
    uint count;
    uint _padding0;
    uint _padding1;
};

struct RoadGlyphInput {
    uint pathIndex;
    uint instanceIndex;
    uint labelInstanceIndex;
    uint _padding;
    float glyphCenter;
    float labelCenterY;
    float labelWidth;
    float spacing;
    float minLength;
};

struct RoadGlyphPlacementOutput {
    float2 position;
    float angle;
    uint visible;
    // The glyph was placed by extrapolating past the path ends: it is drawn as
    // before, but the CPU readback builds no collision candidates from it (the
    // previous CPU path did not show such instances at all).
    uint extrapolated;
};

struct RoadGlyphCollisionOutput {
    float2 halfSizeAABB;
    float2 _padding;
};

struct RoadLabelAnchor {
    uint pathIndex;
    uint segmentIndex;
    float t;
    float distanceAlongPath;
    uint anchorOrdinal;
    uint _padding;
};

#endif
