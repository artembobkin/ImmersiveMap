// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

#ifndef ROAD_LABEL_COMMON
#define ROAD_LABEL_COMMON

// RoadGlyphInput (RoadPathLabel.swift): a glyph's place in its label.
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

// RoadGlyphPlacementOutput (RoadPathLabel.swift): where the glyph is drawn
// this frame, placed on the CPU and uploaded per frame slot.
struct RoadGlyphPlacementOutput {
    float2 position;
    float angle;
    uint visible;
};

#endif
