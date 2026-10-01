// Copyright (c) 2025-2026 ImmersiveMap contributors.
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
                                 const device LabelRuntimeMeta* labelMeta [[buffer(6)]],
                                 constant float& pixelsPerPoint [[buffer(7)]]) {
    VertexOut out;
    int screenIndex = in.labelIndex + globalTextShift;
    ScreenPointOutput screenPoint = screenPositions[screenIndex];
    LabelRuntimeMeta runtimeState = labelMeta[screenIndex];

    // Glyph geometry and the collision box are both in layout points; the screen
    // position the label hangs off is already in device pixels, so the whole
    // label-local offset converts in one multiply.
    // The label shrinks about its anchor for its distance
    // (LabelRuntimeMeta.perspectiveScale), glyphs and box alike.
    float2 halfSize = runtimeState.labelSizePoints * 0.5;
    float2 pixelPosition = screenPoint.position
        + (in.position - halfSize) * (pixelsPerPoint * runtimeState.perspectiveScale);
    out.position = matrix * float4(pixelPosition, 0.0, 1.0);
    // Far-plane depth: the cleared overlay depth (1.0) passes the labels'
    // lessEqual test, and the fill and halo depths written just short of it
    // order the glyphs (TextShader.metal).
    out.position.z = out.position.w;
    out.uv = in.uv;
    bool isVisible = (screenPoint.visible != 0u) &&
                     (runtimeState.fadeAlpha > 0.0);
    out.alpha = isVisible ? runtimeState.fadeAlpha : 0.0;
    if (!isVisible) {
        out.position = hiddenLabelClipPosition();
    }
    out.spriteUV = in.spriteUV;
    return out;
}
