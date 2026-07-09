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
    uchar isRetained;
    ushort _padding;
    uint visibleTileIndex;
    float fadeAlpha;
    float _padding1;
    float2 labelSizePx;
};

#endif
