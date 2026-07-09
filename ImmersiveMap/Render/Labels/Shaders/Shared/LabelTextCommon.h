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

#endif /* LabelTextCommon_h */
