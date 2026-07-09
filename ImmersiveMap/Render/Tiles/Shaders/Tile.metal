// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

// Add necessary structures for transformation and rendering
struct VertexIn {
    short2 position [[attribute(0)]];
    unsigned char styleIndex [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 localPosition;
    float4 color;
    float lowZoomFadeMask;
    float pointSize [[point_size]];
};

struct Style {
    float4 color;
};

struct OverviewFadeUniform {
    float overviewAlpha;
    float roadAlpha;
    float landuseAlpha;
};

vertex VertexOut tileVertexShader(VertexIn vertexIn [[stage_in]],
                                  constant Camera& camera [[buffer(1)]],
                                  constant Style* styles [[buffer(2)]],
                                  constant float4x4& modelMatrix [[buffer(3)]],
                                  constant float* lowZoomFadeMasks [[buffer(4)]]) {
    
    Style style = styles[vertexIn.styleIndex];
    float4x4 matrix = camera.matrix;
    
    float4 worldPosition = modelMatrix * float4(float2(vertexIn.position.xy), 0.0, 1.0);
    float4 clipPosition = matrix * worldPosition;
    
    VertexOut out;
    out.position = clipPosition;
    out.localPosition = float2(vertexIn.position.xy);
    out.pointSize = 5.0;
    out.color = style.color;
    out.lowZoomFadeMask = lowZoomFadeMasks[vertexIn.styleIndex];
    return out;
}

// localClipBounds: (minX, minY, maxX, maxY) в локальных координатах source-тайла.
// Retained-подмена рисуется полным квадом source - фрагменты вне слота placeIn
// отбрасываются, чтобы не перекрывать соседние точные тайлы.
fragment float4 tileFragmentShader(VertexOut in [[stage_in]],
                                   constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                   constant float4& localClipBounds [[buffer(1)]]) {
    if (in.localPosition.x < localClipBounds.x || in.localPosition.y < localClipBounds.y ||
        in.localPosition.x > localClipBounds.z || in.localPosition.y > localClipBounds.w) {
        discard_fragment();
    }
    float4 color = in.color;
    float fade = 1.0;
    if (in.lowZoomFadeMask >= 2.5) {
        fade = overviewFade.landuseAlpha;
    } else if (in.lowZoomFadeMask >= 1.5) {
        fade = overviewFade.roadAlpha;
    } else if (in.lowZoomFadeMask >= 0.5) {
        fade = overviewFade.overviewAlpha;
    }
    color.a *= fade;
    return color;
}
