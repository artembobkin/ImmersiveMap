// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    unsigned char styleIndex [[attribute(2)]];
    uint surfaceID [[attribute(3)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 localPosition;
    float4 color;
    uint surfaceID [[flat]];
    float pointSize [[point_size]];
};

struct Style {
    float4 color;
};

vertex VertexOut tileExtrudedVertexShader(VertexIn vertexIn [[stage_in]],
                                          constant Camera& camera [[buffer(1)]],
                                          constant Style* styles [[buffer(2)]],
                                          constant float4x4& modelMatrix [[buffer(3)]]) {
    Style style = styles[vertexIn.styleIndex];
    float4x4 matrix = camera.matrix;

    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);
    float4 clipPosition = matrix * worldPosition;
    float3x3 normalMatrix = float3x3(modelMatrix[0].xyz, modelMatrix[1].xyz, modelMatrix[2].xyz);
    float3 worldNormal = normalize(normalMatrix * vertexIn.normal);

    VertexOut out;
    out.position = clipPosition;
    out.pointSize = 5.0;
    out.color = style.color;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = worldNormal;
    out.localPosition = vertexIn.position.xy;
    out.surfaceID = vertexIn.surfaceID;
    return out;
}

// localClipBounds: (minX, minY, maxX, maxY) in the source tile's local coordinates.
// A retained substitution draws the source's buildings in full - fragments outside
// the placeIn slot are discarded, otherwise the parent's buildings would cover
// neighboring exact tiles.
static inline bool isOutsideLocalClip(float2 localPosition, float4 localClipBounds) {
    return localPosition.x < localClipBounds.x || localPosition.y < localClipBounds.y ||
           localPosition.x > localClipBounds.z || localPosition.y > localClipBounds.w;
}

// Depth cues without an analytic lighting model (the shading contract stays
// "flat base color + shadow map"): two subtle tonal terms multiply the base
// color so that faces separate where flat shading would merge them.
// - Hemisphere term: roofs keep the base color, walls darken slightly, and
//   the sun-facing side of a wall is a touch lighter than the far side, so
//   the edge between two differently oriented walls is always visible.
// - Vertical gradient: walls darken toward the ground, faking the ambient
//   occlusion of street canyons and visually grounding the buildings
//   (short buildings also read slightly darker than tall ones).
// Both are tonal cues, not lighting: they never exceed 1 and compose with
// the shadow factor and the geometric self-shadow untouched.
constant float kWallShadeBase = 0.94;
constant float kWallShadeSunSwing = 0.03;
constant float kBaseDarkening = 0.90;
constant float kGradientRampMeters = 30.0;

static inline float extrudedDepthCueShade(float3 worldNormal,
                                          float heightMeters,
                                          float3 lightDirection) {
    float upness = saturate(worldNormal.z);

    float sunSide = 0.0;
    float2 horizontalNormal = worldNormal.xy;
    float2 horizontalSun = lightDirection.xy;
    float normalLength = length(horizontalNormal);
    float sunLength = length(horizontalSun);
    // Degenerate cases (roof fragments, shadows disabled with the vertical
    // placeholder sun) fall back to the neutral wall tone.
    if (normalLength > 1e-4 && sunLength > 1e-4) {
        sunSide = dot(horizontalNormal / normalLength, horizontalSun / sunLength);
    }
    float wallShade = kWallShadeBase + kWallShadeSunSwing * sunSide;
    float orientationShade = mix(wallShade, 1.0, upness);

    float gradient = mix(kBaseDarkening, 1.0,
                         smoothstep(0.0, kGradientRampMeters, heightMeters));
    return orientationShade * gradient;
}

// No analytic lighting model: faces keep their flat base color and darken
// only where the shadow map says the static sun is occluded. Walls turned
// away from the sun are occluded by their own building in the map, so they
// come out shadowed exactly like cast shadows: one consistent system.
// Building geometry is always drawn opaque with a regular depth test and MSAA:
// in solid mode - directly into the world pass, in translucent - into the
// offscreen building image, which the world pass then composites over the map
// with a shared alpha.
fragment float4 tileExtrudedFragmentShader(VertexOut in [[stage_in]],
                                           constant float4& localClipBounds [[buffer(4)]],
                                           constant Shadow& shadow [[buffer(5)]],
                                           constant float& metersToWorldZ [[buffer(6)]],
                                           depth2d<float> shadowMap [[texture(0)]]) {
    // Derivatives (inside sampleShadowFactor) must precede the divergent
    // discard, because MSL leaves them undefined in a quad after any lane discards.
    float shadowFactor = sampleShadowFactor(shadow, shadowMap, in.worldPosition, in.worldNormal);
    if (isOutsideLocalClip(in.localPosition, localClipBounds)) {
        discard_fragment();
    }

    float heightMeters = in.worldPosition.z / max(metersToWorldZ, 1e-9);
    float depthCueShade = extrudedDepthCueShade(in.worldNormal, heightMeters, shadow.lightDirection);
    // The cues fade out with the shadow factor: a self-shadowed or cast-shadowed
    // face keeps the pure shadow color instead of stacking darkening on
    // darkening (dark x dark reads unnatural). With shadows disabled the
    // factor is 1 and the cues apply fully.
    float appliedCue = mix(1.0, depthCueShade, shadowFactor);
    return float4(in.color.rgb * appliedCue * shadowFactor, 1.0);
}

// Depth-only path of the shadow map pass: the light's orthographic camera
// arrives in the Camera slot, everything else matches the main draw so both
// replay the same per-tile buffers and model matrices.
struct ExtrudedShadowVertexOut {
    float4 position [[position]];
    float2 localPosition;
};

vertex ExtrudedShadowVertexOut tileExtrudedShadowVertexShader(VertexIn vertexIn [[stage_in]],
                                                              constant Camera& lightCamera [[buffer(1)]],
                                                              constant float4x4& modelMatrix [[buffer(3)]]) {
    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);
    ExtrudedShadowVertexOut out;
    out.position = lightCamera.matrix * worldPosition;
    out.localPosition = vertexIn.position.xy;
    return out;
}

// The fragment stage exists solely to replicate the placeIn clip of the main
// path: without it a retained parent's buildings would cast shadows over
// neighboring exact tiles.
fragment void tileExtrudedShadowFragmentShader(ExtrudedShadowVertexOut in [[stage_in]],
                                               constant float4& localClipBounds [[buffer(4)]]) {
    if (isOutsideLocalClip(in.localPosition, localClipBounds)) {
        discard_fragment();
    }
}

struct ExtrudedCompositeVertexOut {
    float4 position [[position]];
};

vertex ExtrudedCompositeVertexOut tileExtrudedCompositeVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    ExtrudedCompositeVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// Compositing the building image over the map. Inside the image the buildings
// are opaque, but the MSAA resolve of the transparent background leaves the
// silhouette coverage in alpha, with the color premultiplied by that coverage.
// Multiplying by the global alpha and premultiplied blending
// (one / oneMinusSourceAlpha) tint every map pixel exactly once - no matter
// how many building surfaces overlap.
fragment float4 tileExtrudedCompositeFragmentShader(ExtrudedCompositeVertexOut in [[stage_in]],
                                                    texture2d<float, access::read> buildingImage [[texture(0)]],
                                                    constant float& alpha [[buffer(0)]]) {
    float4 premultiplied = buildingImage.read(uint2(in.position.xy));
    return premultiplied * alpha;
}
