// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

// Add necessary structures for transformation and rendering
struct VertexIn {
    short2 position [[attribute(0)]];
    unsigned char styleIndex [[attribute(1)]];
    unsigned char lineEdgeThreshold [[attribute(2)]];
    short lineDistance [[attribute(3)]];
};

// color and the fade mask are unit-range, so they interpolate as half: fewer
// interpolant registers and double-rate ALU on A-series GPUs (the same split
// the starfield shader uses). Positions stay float.
// lineDistance stays float: the antialiasing band can be a small fraction of
// the normalized field on wide lines, below half's precision near 1.0.
struct VertexOut {
    float4 position [[position]];
    float2 localPosition;
    float3 worldPos;
    half4 color;
    half lowZoomFadeMask;
    float lineDistance;
    half lineEdgeThreshold;
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
    out.worldPos = worldPosition.xyz;
    out.color = half4(style.color);
    out.lowZoomFadeMask = half(lowZoomFadeMasks[vertexIn.styleIndex]);
    out.lineDistance = float(vertexIn.lineDistance) / 32767.0;
    out.lineEdgeThreshold = half(vertexIn.lineEdgeThreshold) / 255.0h;
    return out;
}

/// Analytic coverage of line geometry: the tessellator extrudes lines wider
/// than their styled width and stores a signed distance field in the vertices
/// (see `TileVertexIn`), so the visible edge is the `lineEdgeThreshold`
/// isoline of the interpolated field, feathered over one screen pixel. This
/// is the only edge antialiasing lines get on the globe, whose atlas pages
/// render without MSAA. Must be called before any divergent discard: fwidth
/// evaluates screen-space derivatives.
static inline half tileLineCoverage(float lineDistance, half lineEdgeThreshold) {
    // The derivative is taken before the threshold test: fwidth needs the
    // whole 2x2 quad, so it must not sit behind potentially divergent flow.
    float pixelSpan = max(fwidth(lineDistance), 1e-5);
    if (lineEdgeThreshold <= 0.0h) {
        return 1.0h;
    }
    float edgeDistancePx = (float(lineEdgeThreshold) - abs(lineDistance)) / pixelSpan;
    return half(smoothstep(-0.5, 0.5, edgeDistancePx));
}

// localClipBounds: (minX, minY, maxX, maxY) in the source tile's local coordinates.
// A retained substitute is drawn as the full source quad - fragments outside the
// placeIn slot are discarded so they don't overlap neighboring exact tiles.
fragment half4 tileFragmentShader(VertexOut in [[stage_in]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                  constant float4& localClipBounds [[buffer(1)]],
                                  constant HorizonFog& horizonFog [[buffer(2)]],
                                  constant Shadow& shadow [[buffer(3)]],
                                  depth2d_array<float> shadowMap [[texture(0)]]) {
    // The shadow factor and the line coverage come first: both evaluate
    // screen-space derivatives, which are undefined in any 2x2 quad after a
    // divergent discard (MSL spec), so the clip discard must not precede them.
    float shadowFactor = sampleShadowFactor(shadow, shadowMap, in.worldPos, float3(0.0));
    half lineCoverage = tileLineCoverage(in.lineDistance, in.lineEdgeThreshold);
    if (in.localPosition.x < localClipBounds.x || in.localPosition.y < localClipBounds.y ||
        in.localPosition.x > localClipBounds.z || in.localPosition.y > localClipBounds.w) {
        discard_fragment();
    }
    half4 color = in.color;
    half fade = 1.0h;
    if (in.lowZoomFadeMask >= 2.5h) {
        fade = half(overviewFade.landuseAlpha);
    } else if (in.lowZoomFadeMask >= 1.5h) {
        fade = half(overviewFade.roadAlpha);
    } else if (in.lowZoomFadeMask >= 0.5h) {
        fade = half(overviewFade.overviewAlpha);
    }
    color.a *= fade * lineCoverage;
    // Shadow before fog: fog wins at distance, so the shadow-coverage edge
    // dissolves into the haze instead of cutting a visible line. Zero normal
    // (passed above): the ground always faces the sun and keeps its tight
    // contact (no normal-offset shift).
    color.rgb *= half(shadowFactor);
    color.rgb = applyHorizonFog(color.rgb, horizonFog, in.worldPos);
    return color;
}
