// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Screen/ScreenCommon.h"
#include "AvatarCommon.h"

struct BeamVertexOut {
    float4 position [[position]];
    float alpha;
};

vertex BeamVertexOut avatarBeamVertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      constant float4x4& screenMatrix [[buffer(0)]],
                                      const device ScreenPointOutput* points [[buffer(1)]],
                                      const device AvatarOffset* offsets [[buffer(2)]],
                                      constant float& beamWidth [[buffer(3)]],
                                      constant float& avatarSizePx [[buffer(4)]]) {
    const uint triIndices[6] = { 0, 1, 2, 0, 2, 1 };

    BeamVertexOut out;
    ScreenPointOutput point = points[iid];
    if (point.visible == 0) {
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.alpha = 0.0;
        return out;
    }
    float2 markerCenterOffset = float2(0.0, avatarSizePx * 0.5);
    float2 anchor = point.position + markerCenterOffset;
    float2 target = anchor + offsets[iid].value;
    float2 dir = target - anchor;
    float len = length(dir);
    float radius = avatarSizePx * offsets[iid].scale * 0.5;
    if (len <= radius + 1.0 || beamWidth <= 0.0) {
        out.position = float4(-2.0, -2.0, 0.0, 1.0);
        out.alpha = 0.0;
        return out;
    }

    float2 dirNorm = dir / len;
    float2 perp = float2(-dirNorm.y, dirNorm.x);
    float tangentX = -radius * radius / len;
    float tangentY = radius * sqrt(max(len * len - radius * radius, 0.0)) / len;
    float2 tangentLeft = target + dirNorm * tangentX + perp * tangentY;
    float2 tangentRight = target + dirNorm * tangentX - perp * tangentY;

    uint idx = triIndices[vid];
    float2 pos = anchor;
    if (idx == 1) {
        pos = tangentLeft;
    } else if (idx == 2) {
        pos = tangentRight;
    }
    out.position = screenMatrix * float4(pos, 0.0, 1.0);
    out.alpha = (idx == 0) ? 0.15 : 1.0;
    return out;
}

fragment float4 avatarBeamFragment(BeamVertexOut in [[stage_in]],
                                  constant float4& beamColor [[buffer(0)]]) {
    return float4(beamColor.rgb, beamColor.a * in.alpha);
}
