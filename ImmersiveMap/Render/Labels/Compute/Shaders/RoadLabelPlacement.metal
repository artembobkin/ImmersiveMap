// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../../Shaders/Screen/ScreenCommon.h"
#include "../../Shaders/Shared/ScreenCollisionCommon.h"
#include "../../Shaders/Road/RoadLabelCommon.h"

kernel void roadLabelPlacementKernel(const device ScreenPointOutput* pathPoints [[buffer(0)]],
                                     const device RoadPathRange* pathRanges [[buffer(1)]],
                                     const device RoadLabelAnchor* anchors [[buffer(2)]],
                                     const device RoadGlyphInput* glyphInputs [[buffer(3)]],
                                     device RoadGlyphPlacementOutput* placements [[buffer(4)]],
                                     device ScreenPointOutput* screenPoints [[buffer(5)]],
                                     constant uint& glyphCount [[buffer(6)]],
                                     const device ScreenCollisionInput* collisionInputs [[buffer(7)]],
                                     device RoadGlyphCollisionOutput* collisionAabb [[buffer(8)]],
                                     uint gid [[thread_position_in_grid]]) {
    if (gid >= glyphCount) {
        return;
    }

    RoadGlyphInput input = glyphInputs[gid];
    RoadPathRange pathRange = pathRanges[input.pathIndex];
    RoadLabelAnchor anchor = anchors[input.labelInstanceIndex];

    // Keep placement state across frames; fallback placement still stays anchored to the path.
    RoadGlyphPlacementOutput placement = placements[gid];
    placement.extrapolated = 0;

    ScreenPointOutput screenPoint;
    screenPoint.position = float2(0.0);
    screenPoint.depth = 0.0;
    screenPoint.visible = 0;
    screenPoint.visibilityAlpha = 0.0;

    RoadGlyphCollisionOutput collisionOut;
    collisionOut.halfSizeAABB = float2(0.0);
    collisionOut._padding = float2(0.0);

    if (pathRange.count < 2) {
        placement.visible = 0;
        placements[gid] = placement;
        screenPoints[gid] = screenPoint;
        collisionAabb[gid] = collisionOut;
        return;
    }

    float totalLength = 0.0;
    float anchorDistance = -1.0;
    bool hasInvisible = false;
    uint start = pathRange.start;
    uint end = start + pathRange.count;
    uint anchorSegmentIndex = min(anchor.segmentIndex, pathRange.count - 2);
    float anchorT = clamp(anchor.t, 0.0, 1.0);

    float2 startPos = pathPoints[start].position;
    float2 endPos = pathPoints[end - 1].position;
    float2 overall = endPos - startPos;
    bool reverse = false;
    if (length(overall) > 0.0) {
        float overallAngle = atan2(overall.y, overall.x);
        reverse = (overallAngle > M_PI_2_F || overallAngle < -M_PI_2_F);
    }

    float2 prev = startPos;
    if (pathPoints[start].visible == 0) {
        hasInvisible = true;
    }

    for (uint i = start + 1; i < end; i++) {
        ScreenPointOutput point = pathPoints[i];
        if (point.visible == 0) {
            hasInvisible = true;
        }
        float2 current = point.position;
        float segmentLength = length(current - prev);
        uint segmentIndex = i - start - 1;
        if (segmentIndex == anchorSegmentIndex) {
            anchorDistance = totalLength + segmentLength * anchorT;
        }
        totalLength += segmentLength;
        prev = current;
    }

    if (hasInvisible) {
        placement.visible = 0;
        placements[gid] = placement;
        screenPoints[gid] = screenPoint;
        collisionAabb[gid] = collisionOut;
        return;
    }

    float glyphOffset = input.glyphCenter - input.labelWidth * 0.5;
    if (reverse) {
        glyphOffset = -glyphOffset;
    }

    float targetDistance = anchorDistance + glyphOffset;
    bool canDraw = (totalLength >= input.minLength);

    placement.visible = 0;
    float2 position = float2(0.0);
    float angle = 0.0;
    bool placed = false;

    if (targetDistance <= 0.0) {
        float2 p0 = pathPoints[start].position;
        float2 p1 = pathPoints[start + 1].position;
        float2 dir = p1 - p0;
        float segLen = length(dir);
        if (segLen > 0.0) {
            dir /= segLen;
            position = p0 + dir * targetDistance;
            angle = atan2(dir.y, dir.x);
            placed = true;
            placement.extrapolated = 1;
        }
    } else if (targetDistance >= totalLength) {
        float2 p0 = pathPoints[end - 2].position;
        float2 p1 = pathPoints[end - 1].position;
        float2 dir = p1 - p0;
        float segLen = length(dir);
        if (segLen > 0.0) {
            dir /= segLen;
            position = p1 + dir * (targetDistance - totalLength);
            angle = atan2(dir.y, dir.x);
            placed = true;
            placement.extrapolated = 1;
        }
    } else {
        float accumulated = 0.0;
        float2 p0 = pathPoints[start].position;
        for (uint i = start + 1; i < end; i++) {
            float2 p1 = pathPoints[i].position;
            float segmentLength = length(p1 - p0);
            if (segmentLength > 0.0) {
                if (accumulated + segmentLength >= targetDistance) {
                    float t = (targetDistance - accumulated) / segmentLength;
                    position = mix(p0, p1, t);
                    float2 dir = normalize(p1 - p0);
                    angle = atan2(dir.y, dir.x);
                    placed = true;
                    break;
                }
                accumulated += segmentLength;
            }
            p0 = p1;
        }
    }

    if (placed) {
        if (reverse) {
            angle += M_PI_F;
        }
        placement.position = position;
        placement.angle = angle;
    }
    if (placed && canDraw) {
        placement.visible = 1;
        screenPoint.position = position;
        screenPoint.depth = 0.0;
        screenPoint.visible = 1;
    }

    if (placement.visible != 0) {
        ScreenCollisionInput collisionInput = collisionInputs[gid];
        float2 halfSize = collisionInput.halfSize;
        float s = sin(placement.angle);
        float c = cos(placement.angle);
        collisionOut.halfSizeAABB = float2(abs(c) * halfSize.x + abs(s) * halfSize.y,
                                           abs(s) * halfSize.x + abs(c) * halfSize.y);
    }

    placements[gid] = placement;
    screenPoints[gid] = screenPoint;
    collisionAabb[gid] = collisionOut;
}
