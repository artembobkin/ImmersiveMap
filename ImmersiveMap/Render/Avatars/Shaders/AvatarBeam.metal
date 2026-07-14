// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Screen/ScreenCommon.h"
#include "AvatarCommon.h"

// Пороги проявления согласованы с AvatarCollisionMath.displacedMorph*:
// луч появляется вместе с превращением сдвинутого маркера в кружок.
constant float kDisplacedRevealStartPx = 2.0;
constant float kDisplacedRevealEndPx = 10.0;

static inline float beamReveal(float displacementLength) {
    return smoothstep(kDisplacedRevealStartPx, kDisplacedRevealEndPx, displacementLength);
}

struct BeamVertexOut {
    float4 position [[position]];
    float alpha;
    /// 0 у геоточки, 1 у кружка: луч затухает при приближении к геоточке.
    float taper;
};

// Конус от геоточки к сдвинутому кружку: вершина на якоре, основание - две
// касательные точки окружности тела («от края до края»). Рисуется только у
// кружочков: несдвинутый маркер имеет нулевое смещение и конус скрыт.
vertex BeamVertexOut avatarBeamVertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      constant float4x4& screenMatrix [[buffer(0)]],
                                      const device ScreenPointOutput* points [[buffer(1)]],
                                      const device AvatarOffset* offsets [[buffer(2)]],
                                      constant AvatarBeamStyleGPU& style [[buffer(3)]]) {
    const uint triIndices[6] = { 0, 1, 2, 0, 2, 1 };

    BeamVertexOut out;
    out.position = float4(-2.0, -2.0, 0.0, 1.0);
    out.alpha = 0.0;
    out.taper = 0.0;

    ScreenPointOutput point = points[iid];
    AvatarOffset offset = offsets[iid];
    if (point.visible == 0) {
        return out;
    }

    float2 anchor = point.position;
    float2 bubbleCenter = anchor + offset.value + float2(0.0, style.markerCenterOffsetPx * offset.scale);
    float2 direction = bubbleCenter - anchor;
    float len = length(direction);
    float radius = max(style.markerBodyHalfMinPx * offset.scale, 1.0);
    if (len <= radius + 1.0) {
        return out;
    }

    float alpha = beamReveal(length(offset.value)) * point.visibilityAlpha;
    if (alpha <= 0.001) {
        return out;
    }

    float2 dirNorm = direction / len;
    float2 perp = float2(-dirNorm.y, dirNorm.x);
    float tangentX = -radius * radius / len;
    float tangentY = radius * sqrt(max(len * len - radius * radius, 0.0)) / len;
    float2 tangentLeft = bubbleCenter + dirNorm * tangentX + perp * tangentY;
    float2 tangentRight = bubbleCenter + dirNorm * tangentX - perp * tangentY;

    float2 corners[3] = { anchor, tangentLeft, tangentRight };
    float cornerTapers[3] = { 0.0, 1.0, 1.0 };

    uint corner = triIndices[vid];
    out.position = screenMatrix * float4(corners[corner], 0.0, 1.0);
    out.alpha = alpha;
    out.taper = cornerTapers[corner];
    return out;
}

fragment float4 avatarBeamFragment(BeamVertexOut in [[stage_in]],
                                   constant float4& beamColor [[buffer(0)]]) {
    // Кубическое затухание к геоточке: у кружка луч плотный, к фактической
    // геоточке растворяется задолго до вершины конуса.
    float taper = in.taper * in.taper * in.taper;
    return float4(beamColor.rgb, beamColor.a * in.alpha * taper);
}
