// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"
#include "../../Shaders/Screen/ScreenCommon.h"
#include "../../Shaders/Screen/ScreenPoint.h"
#include "../../Shaders/Globe/GlobeTileProjection.h"
#include "AvatarCommon.h"

kernel void avatarGeoPointToScreenGlobeAndTransitionKernel(const device AvatarGeoInput* inputs [[buffer(0)]],
                                                           device ScreenPointOutput* outputs [[buffer(1)]],
                                                           constant Camera& camera [[buffer(2)]],
                                                           constant Globe& globe [[buffer(3)]],
                                                           constant ScreenParams& screenParams [[buffer(4)]],
                                                           constant uint& count [[buffer(5)]],
                                                           uint gid [[thread_position_in_grid]]) {
    if (gid >= count) {
        return;
    }
    AvatarGeoInput input = inputs[gid];
    GlobeVisibilityProjectionResult projection = globeProjectLatLonFromTile(input.latitude, input.longitude, camera, globe);
    float4 clip = projection.clip;
    ScreenPointOutput result = screenPointFromClip(clip, screenParams);
    if (result.visible == 0) {
        outputs[gid] = result;
        return;
    }

    if (globePointPassesVisibility(projection.worldPosition, camera, globe) == false) {
        result.visible = 0;
        result.visibilityAlpha = 0.0;
    }
    outputs[gid] = result;
}

kernel void avatarWorldPointToScreenFlatKernel(const device float2* inputs [[buffer(0)]],
                                               device ScreenPointOutput* outputs [[buffer(1)]],
                                               constant Camera& camera [[buffer(2)]],
                                               constant ScreenParams& screenParams [[buffer(3)]],
                                               constant uint& count [[buffer(4)]],
                                               uint gid [[thread_position_in_grid]]) {
    if (gid >= count) {
        return;
    }
    float2 pos = inputs[gid];
    float4 clip = camera.matrix * float4(pos, 0.0, 1.0);
    ScreenPointOutput result = screenPointFromClip(clip, screenParams);
    outputs[gid] = result;
}
