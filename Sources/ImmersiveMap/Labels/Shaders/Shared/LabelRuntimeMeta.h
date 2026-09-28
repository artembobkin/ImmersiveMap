// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LabelRuntimeMeta.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;

#ifndef LABEL_RUNTIME_META
#define LABEL_RUNTIME_META

struct LabelRuntimeMeta {
    uchar duplicate;
    uchar _padding0;
    ushort _padding;
    uint visibleTileIndex;
    float fadeAlpha;
    // LabelRuntimeMeta.perspectiveScale: the label's shrink for its distance.
    float perspectiveScale;
    float2 labelSizePoints;
};

#endif
