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

// LabelRuntimeMeta.swift: 16 bytes per label, written every frame.
struct LabelRuntimeMeta {
    float fadeAlpha;
    // The label's shrink for its distance.
    float perspectiveScale;
    float2 labelSizePoints;
};

#endif
