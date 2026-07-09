// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TilePointToScreen.metal
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "../../../Shaders/Shared/RenderUniforms.h"
#include "../../../Shaders/Screen/ScreenCommon.h"
#include "../../../Shaders/Screen/ScreenPoint.h"
#include "../../../Shaders/Globe/GlobeTileProjection.h"
#include "../../../Shaders/Globe/GlobeVisibility.h"

struct TilePointInputGpu {
    float2 uv;
    float2 _padding0;
    int3 tile;
    uint tileSlotIndex;
    uint _padding1;
    uint _padding2;
    uint _padding3;
};

struct FlatTileOriginDataGpu {
    float2 panRelativeOrigin;
    float size;
    float padding;
};

kernel void tilePointToScreenFlatKernel(const device TilePointInputGpu* inputs [[buffer(0)]],
                                        const device uint* tileSlotVisibleTileIndices [[buffer(1)]],
                                        const device FlatTileOriginDataGpu* tileOriginData [[buffer(2)]],
                                        device ScreenPointOutput* outputs [[buffer(3)]],
                                        constant Camera& camera [[buffer(4)]],
                                        constant ScreenParams& screenParams [[buffer(5)]],
                                        constant uint& count [[buffer(6)]],
                                        uint gid [[thread_position_in_grid]]) {
    if (gid >= count) {
        return;
    }

    TilePointInputGpu input = inputs[gid];
    uint tileSlotIndex = input.tileSlotIndex;
    uint visibleTileIndex = tileSlotVisibleTileIndices[tileSlotIndex];
    FlatTileOriginDataGpu originData = tileOriginData[visibleTileIndex];
    float2 local = float2(input.uv.x * originData.size,
                          (1.0 - input.uv.y) * originData.size);
    float2 worldPosition = originData.panRelativeOrigin + local;
    float4 clip = camera.matrix * float4(worldPosition, 0.0, 1.0);
    outputs[gid] = screenPointFromClip(clip, screenParams);
}

kernel void tilePointToScreenGlobeKernel(const device TilePointInputGpu* inputs [[buffer(0)]],
                                         device ScreenPointOutput* outputs [[buffer(1)]],
                                         constant Camera& camera [[buffer(2)]],
                                         constant Globe& globe [[buffer(3)]],
                                         constant ScreenParams& screenParams [[buffer(4)]],
                                         constant uint& count [[buffer(5)]],
                                         uint gid [[thread_position_in_grid]]) {
    if (gid >= count) {
        return;
    }

    TilePointInputGpu input = inputs[gid];
    GlobeVisibilityProjectionResult projection = globeProjectTileUV(input.uv,
                                                                   input.tile,
                                                                   camera,
                                                                   globe);
    ScreenPointOutput result = screenPointFromClip(projection.clip, screenParams);
    if (result.visible != 0) {
        result.visibilityAlpha = 1.0;
    }
    outputs[gid] = result;
}
