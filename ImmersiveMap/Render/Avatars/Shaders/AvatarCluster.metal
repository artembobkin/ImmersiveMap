// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Screen/ScreenCommon.h"
#include "AvatarCommon.h"

struct AvatarOffsetParams {
    uint count;
    float liftPx;
    float smoothing;
    float _padding;
};

kernel void avatarOffsetKernel(const device ScreenPointOutput* points [[buffer(0)]],
                               const device AvatarOffset* offsetsIn [[buffer(1)]],
                               device AvatarOffset* offsetsOut [[buffer(2)]],
                               constant AvatarOffsetParams& params [[buffer(3)]],
                               uint gid [[thread_position_in_grid]]) {
    if (gid >= params.count) {
        return;
    }
    ScreenPointOutput point = points[gid];
    if (point.visible == 0) {
        offsetsOut[gid].value = float2(0.0);
        offsetsOut[gid].scale = 1.0;
        offsetsOut[gid]._padding = 0.0;
        return;
    }

    float2 target = float2(0.0, params.liftPx);
    float smoothing = clamp(params.smoothing, 0.0, 1.0);
    offsetsOut[gid].value = mix(offsetsIn[gid].value, target, smoothing);
    offsetsOut[gid].scale = 1.0;
    offsetsOut[gid]._padding = 0.0;
}
