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

// How far a glyph's place on the road moves toward the eye before its depth
// is taken, as a fraction of the distance: clear of the ground it lies on,
// without leaving its pixel. A wall between the road and the camera is
// nearer by far more.
constant float kRoadGlyphEyeStep = 0.01;

// The depth of the road under a glyph: its pixel carried back along the eye
// ray to the ground plane (z = 0), a step toward the eye, and projected. The
// placement lays the glyphs out in pixels from the path projected onto that
// plane, bottom-left origin. 0 where there is no such point, which no depth
// is nearer than, so nothing is cut.
static inline float roadGlyphAnchorDepth(float2 pixel,
                                         constant RoadLabelSceneDepthUniforms& scene) {
    if (any(scene.viewportSize <= 0.0)) {
        return 0.0;
    }
    float2 ndc = pixel / scene.viewportSize * 2.0 - 1.0;
    float4 nearPoint = scene.inverseProjectionView * float4(ndc, 0.0, 1.0);
    float4 farPoint = scene.inverseProjectionView * float4(ndc, 0.5, 1.0);
    if (abs(nearPoint.w) < 1e-9 || abs(farPoint.w) < 1e-9) {
        return 0.0;
    }
    float3 a = nearPoint.xyz / nearPoint.w;
    float3 b = farPoint.xyz / farPoint.w;
    float heightChange = a.z - b.z;
    if (abs(heightChange) < 1e-9) {
        return 0.0;
    }
    float3 ground = a + (b - a) * (a.z / heightChange);
    float3 anchor = ground + (scene.eye - ground) * kRoadGlyphEyeStep;
    float4 clip = scene.projectionView * float4(anchor, 1.0);
    return clip.w > 0.0 ? clip.z / clip.w : 0.0;
}

vertex RoadTextVertexOut roadLabelTextVertex(LabelVertexIn in [[stage_in]],
                                             constant float4x4& matrix [[buffer(1)]],
                                             const device RoadGlyphPlacementOutput* placements [[buffer(2)]],
                                             const device RoadGlyphInput* glyphInputs [[buffer(3)]],
                                             const device LabelRuntimeMeta* runtimeMeta [[buffer(4)]],
                                             constant int& globalGlyphShift [[buffer(5)]],
                                             constant float2& screenOffset [[buffer(6)]],
                                             constant float& pixelsPerPoint [[buffer(7)]],
                                             constant RoadLabelSceneDepthUniforms& scene [[buffer(8)]]) {
    RoadTextVertexOut out;
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
    // lessEqual test, and the fill and halo depths written just short of it
    // order the glyphs (TextShader.metal).
    out.position.z = out.position.w;
    out.uv = in.uv;
    bool isVisible = placement.visible != 0u && meta.fadeAlpha > 0.0;
    out.alpha = isVisible ? meta.fadeAlpha : 0.0;
    if (!isVisible) {
        out.position = hiddenLabelClipPosition();
    }
    out.spriteUV = in.spriteUV;
    // The whole glyph stands where it touches the road, like a sign: a wall
    // behind the road leaves it whole, one in front cuts it.
    out.anchorDepth = scene.enabled != 0 && isVisible
        ? roadGlyphAnchorDepth(placement.position, scene)
        : 0.0;
    return out;
}
