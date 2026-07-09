// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

struct VertexIn {
    float4 position [[attribute(0)]];
    float4 color [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
};

vertex VertexOut polygonVertexShader(VertexIn in [[stage_in]],
                                     constant Camera& camera [[buffer(1)]]) {
    float4x4 matrix = camera.matrix;
    
    VertexOut out;
    out.position = matrix * in.position;
    out.color = in.color;
    out.pointSize = 10.0;
    return out;
}

fragment float4 polygonFragmentShader(VertexOut in [[stage_in]]) {
    return in.color; 
}
