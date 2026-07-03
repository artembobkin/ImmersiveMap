// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  LabelTextVertex.metal
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/LabelRuntimeMeta.h"
#include "../Shared/LabelTextCommon.h"

vertex VertexOut labelTextVertex(LabelVertexIn in [[stage_in]],
                                 constant float4x4& matrix [[buffer(1)]],
                                 const device ScreenPointOutput* screenPositions [[buffer(2)]],
                                 constant int& globalTextShift [[buffer(3)]],
                                 const device LabelRuntimeMeta* labelMeta [[buffer(6)]]) {
    VertexOut out;
    int screenIndex = in.labelIndex + globalTextShift;
    ScreenPointOutput screenPoint = screenPositions[screenIndex];
    LabelRuntimeMeta runtimeState = labelMeta[screenIndex];

    float2 halfSize = runtimeState.labelSizePx * 0.5;
    float2 pixelPosition = screenPoint.position + in.position - halfSize;
    out.position = matrix * float4(pixelPosition, 0.0, 1.0);
    out.uv = in.uv;
    bool isVisible = (screenPoint.visible != 0u) &&
                     (runtimeState.duplicate == 0u);
    out.alpha = isVisible ? runtimeState.fadeAlpha : 0.0;
    out.spriteUV = in.spriteUV;
    return out;
}
