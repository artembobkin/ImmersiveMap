// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

#ifndef SCREEN_COLLISION_COMMON
#define SCREEN_COLLISION_COMMON

enum ScreenCollisionShapeType {
    ScreenCollisionShapeRect = 0,
    ScreenCollisionShapeCircle = 1
};

struct ScreenCollisionInput {
    float2 halfSize; // Rect half-size in pixels
    float radius;    // Circle radius in pixels
    uint shapeType;  // ScreenCollisionShapeType
};

struct ScreenCollisionParams {
    uint count;
    uint _padding0;
    uint _padding1;
    uint _padding2;
};

static inline bool rectRectCollision(float2 aPos, float2 aHalf, float2 bPos, float2 bHalf) {
    float2 d = abs(aPos - bPos);
    float2 overlap = aHalf + bHalf;
    return (d.x < overlap.x) && (d.y < overlap.y);
}

static inline bool circleCircleCollision(float2 aPos, float aRadius, float2 bPos, float bRadius) {
    float2 d = aPos - bPos;
    float r = aRadius + bRadius;
    return dot(d, d) < r * r;
}

static inline bool rectCircleCollision(float2 rectPos, float2 rectHalf, float2 circlePos, float circleRadius) {
    float2 delta = abs(circlePos - rectPos) - rectHalf;
    float2 clamped = max(delta, float2(0.0));
    return dot(clamped, clamped) < circleRadius * circleRadius;
}

static inline bool screenCollisionIntersects(float2 aPos,
                                             ScreenCollisionInput aInput,
                                             float2 bPos,
                                             ScreenCollisionInput bInput) {
    if (aInput.shapeType == ScreenCollisionShapeRect && bInput.shapeType == ScreenCollisionShapeRect) {
        return rectRectCollision(aPos, aInput.halfSize, bPos, bInput.halfSize);
    }
    if (aInput.shapeType == ScreenCollisionShapeCircle && bInput.shapeType == ScreenCollisionShapeCircle) {
        return circleCircleCollision(aPos, aInput.radius, bPos, bInput.radius);
    }
    if (aInput.shapeType == ScreenCollisionShapeRect && bInput.shapeType == ScreenCollisionShapeCircle) {
        return rectCircleCollision(aPos, aInput.halfSize, bPos, bInput.radius);
    }
    if (aInput.shapeType == ScreenCollisionShapeCircle && bInput.shapeType == ScreenCollisionShapeRect) {
        return rectCircleCollision(bPos, bInput.halfSize, aPos, aInput.radius);
    }
    return false;
}

#endif
