// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RoadLabelTextVertex.metal
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/LabelTextCommon.h"
#include "../Shared/LabelRuntimeMeta.h"
#include "RoadLabelCommon.h"

vertex VertexOut roadLabelTextVertex(LabelVertexIn in [[stage_in]],
                                     constant float4x4& matrix [[buffer(1)]],
                                     const device RoadGlyphPlacementOutput* placements [[buffer(2)]],
                                     const device RoadGlyphInput* glyphInputs [[buffer(3)]],
                                     const device LabelRuntimeMeta* runtimeMeta [[buffer(4)]],
                                     constant int& globalGlyphShift [[buffer(5)]],
                                     constant float2& screenOffset [[buffer(6)]],
                                     constant float& pixelsPerPoint [[buffer(7)]]) {
    VertexOut out;
    int glyphIndex = in.labelIndex + globalGlyphShift;
    RoadGlyphPlacementOutput placement = placements[glyphIndex];
    RoadGlyphInput glyphInput = glyphInputs[glyphIndex];
    uint instanceIndex = glyphInput.labelInstanceIndex;
    LabelRuntimeMeta meta = runtimeMeta[instanceIndex];

    // Glyph geometry is in layout points; the placement the glyph hangs off was
    // resolved along a path that is already in device pixels.
    float2 local = (in.position - float2(glyphInput.glyphCenter, glyphInput.labelCenterY)) * pixelsPerPoint;
    float s = sin(placement.angle);
    float c = cos(placement.angle);
    float2 rotated = float2(local.x * c - local.y * s, local.x * s + local.y * c);
    float2 pixelPosition = placement.position + rotated + screenOffset;

    out.position = matrix * float4(pixelPosition, 0.0, 1.0);
    // Far-plane depth: the cleared overlay depth (1.0) passes the labels'
    // lessEqual test, while the scene model occlusion prepass depth, always
    // closer, clips the label to the model silhouette.
    out.position.z = out.position.w;
    out.uv = in.uv;
    out.alpha = placement.visible != 0u ? meta.fadeAlpha : 0.0;
    out.spriteUV = in.spriteUV;
    return out;
}
