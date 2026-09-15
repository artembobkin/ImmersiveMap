// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LabelTextCommon.h
//  ImmersiveMap
//

#ifndef LabelTextCommon_h
#define LabelTextCommon_h

struct LabelVertexIn {
    float2 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
    int labelIndex [[attribute(2)]];
    float2 spriteUV [[attribute(3)]];
};

struct ScreenPointOutput {
    float2 position;
    float depth;
    uint visible;
    float visibilityAlpha;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
    float2 spriteUV;
};

/// The clip position of a hidden label's vertices: outside the clip volume
/// on one side, so the rasterizer rejects the primitive whole and no
/// fragment is ever shaded for a label that lost its collision, is a
/// duplicate or lies beyond the horizon. Every vertex of a label shares
/// the label's visibility, so the whole quad moves together and never
/// straddles the volume. Alpha 0 alone would leave the quads rasterized
/// at full fragment cost for nothing.
static inline float4 hiddenLabelClipPosition() {
    return float4(-2.0, -2.0, 0.0, 1.0);
}

#endif /* LabelTextCommon_h */
