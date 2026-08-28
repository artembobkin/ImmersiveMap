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

// color and the unit normal are unit-range, so they interpolate as half:
// fewer interpolant registers and double-rate ALU on A-series GPUs. World
// position stays float for the shadow projection.
struct VertexOut {
    float4 position [[position]];
    // Signed distances to the four edges of the placeIn slot in the source
    // tile's local units (see localClipBounds); the rasterizer clips where
    // any goes negative, so the fragment stage needs no discard and the GPU
    // can drop covered fragments before shading them.
    float clipDistance [[clip_distance]] [4];
    float3 worldPosition;
    half3 worldNormal;
    half4 color;
};

// The fragment stage's view of VertexOut, matched by name and without the
// clip distances (consumed by the rasterizer; not allowed in stage_in).
struct FragmentIn {
    float4 position [[position]];
    float3 worldPosition;
    half3 worldNormal;
    half4 color;
};

struct Style {
    float4 color;
    /// Mirror of TilePolygonStyle: buildings are street-only, so this stays
    /// unused here, but the stride must match the shared style buffer.
    float4 streetColor;
};

// localClipBounds: (minX, minY, maxX, maxY) in the source tile's local
// coordinates. A retained substitution draws the source's buildings in full,
// clipped to the placeIn slot by the rasterizer, otherwise the parent's
// buildings would cover neighboring exact tiles. Exact placements carry a
// disabled clip, so every distance stays positive.
static inline void writeLocalClipDistances(thread float (&clipDistance)[4],
                                           float2 localPosition,
                                           float4 localClipBounds) {
    clipDistance[0] = localPosition.x - localClipBounds.x;
    clipDistance[1] = localClipBounds.z - localPosition.x;
    clipDistance[2] = localPosition.y - localClipBounds.y;
    clipDistance[3] = localClipBounds.w - localPosition.y;
}

vertex VertexOut tileExtrudedVertexShader(VertexIn vertexIn [[stage_in]],
                                          constant Camera& camera [[buffer(1)]],
                                          constant Style* styles [[buffer(2)]],
                                          constant float4x4& modelMatrix [[buffer(3)]],
                                          constant float4& localClipBounds [[buffer(4)]]) {
    Style style = styles[vertexIn.styleIndex];
    float4x4 matrix = camera.matrix;

    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);
    float4 clipPosition = matrix * worldPosition;
    float3x3 normalMatrix = float3x3(modelMatrix[0].xyz, modelMatrix[1].xyz, modelMatrix[2].xyz);
    float3 worldNormal = normalize(normalMatrix * vertexIn.normal);

    VertexOut out;
    out.position = clipPosition;
    out.color = half4(style.color);
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = half3(worldNormal);
    writeLocalClipDistances(out.clipDistance, vertexIn.position.xy, localClipBounds);
    return out;
}


// Depth cues without an analytic lighting model (the shading contract stays
// "flat base color + shadow map"): two subtle tonal terms multiply the base
// color so that faces separate where flat shading would merge them.
// - Hemisphere term: roofs keep the base color, walls darken slightly, and
//   the sun-facing side of a wall is lighter than the far side, so the edge
//   between two differently oriented walls is always visible and a block
//   reads as a lit solid: even a wall square to the sun stays a step under
//   the roof, so the roof edge never dissolves into a lit facade, and one
//   turned away drops toward the self-shadow the shadow map gives it, so
//   roof, lit wall, side wall and shaded wall are four distinct tones.
// - Vertical gradient: walls darken toward the ground, faking the ambient
//   occlusion of street canyons and visually grounding the buildings
//   (short buildings also read slightly darker than tall ones).
// Both are tonal cues, not lighting: they never exceed 1 and compose with
// the shadow factor and the geometric self-shadow untouched.
constant half kWallShadeBase = 0.90h;
constant half kWallShadeSunSwing = 0.07h;
constant half kBaseDarkening = 0.88h;
constant half kGradientRampMeters = 30.0h;

// Unit-range tonal math runs in half; heights saturate the 30 m ramp far
// below half's range, so nothing here needs float.
static inline half extrudedDepthCueShade(half3 worldNormal,
                                         half heightMeters,
                                         half3 lightDirection) {
    half upness = saturate(worldNormal.z);

    half sunSide = 0.0h;
    half2 horizontalNormal = worldNormal.xy;
    half2 horizontalSun = lightDirection.xy;
    half normalLength = length(horizontalNormal);
    half sunLength = length(horizontalSun);
    // Degenerate cases (roof fragments, shadows disabled with the vertical
    // placeholder sun) fall back to the neutral wall tone.
    if (normalLength > 1.0e-3h && sunLength > 1.0e-3h) {
        sunSide = dot(horizontalNormal / normalLength, horizontalSun / sunLength);
    }
    half wallShade = kWallShadeBase + kWallShadeSunSwing * sunSide;
    half orientationShade = mix(wallShade, 1.0h, upness);

    half gradient = mix(kBaseDarkening, 1.0h,
                        smoothstep(0.0h, kGradientRampMeters, heightMeters));
    return orientationShade * gradient;
}

// No analytic lighting model: faces keep their flat base color and darken
// only where the shadow map says the static sun is occluded. Walls turned
// away from the sun are occluded by their own building in the map, so they
// come out shadowed exactly like cast shadows: one consistent system.
// Building geometry is always drawn opaque with a regular depth test and MSAA:
// in solid mode - directly into the world pass, in translucent - into the
// building image (a separate offscreen pass, or the world pass's second
// memoryless attachment on GPUs with framebuffer fetch), which is then
// composited over the map with a shared alpha.
static inline half4 shadeExtrudedFragment(FragmentIn in,
                                          constant Shadow& shadow,
                                          constant float& metersToWorldZ,
                                          depth2d_array<float> shadowMap) {
    half shadowFactor = half(sampleShadowFactor(shadow, shadowMap,
                                                in.worldPosition, float3(in.worldNormal)));

    // The meters conversion stays float: metersToWorldZ can be tiny and the
    // guard ratio overflows half, which the saturating ramp then absorbs.
    float heightMeters = in.worldPosition.z / max(metersToWorldZ, 1e-9);
    half depthCueShade = extrudedDepthCueShade(in.worldNormal,
                                               half(min(heightMeters, 1.0e4)),
                                               half3(shadow.lightDirection));
    // The cues fade out with the shadow factor: a self-shadowed or cast-shadowed
    // face keeps the pure shadow color instead of stacking darkening on
    // darkening (dark x dark reads unnatural). With shadows disabled the
    // factor is 1 and the cues apply fully. The factor is applied through
    // the tinted multiplier, so shadowed faces take on the sky cast the
    // ground under them takes on: one shadow color across the scene.
    half appliedCue = mix(1.0h, depthCueShade, shadowFactor);
    return half4(in.color.rgb * appliedCue * shadowColorMultiplier(shadow, shadowFactor), 1.0h);
}

fragment half4 tileExtrudedFragmentShader(FragmentIn in [[stage_in]],
                                          constant Shadow& shadow [[buffer(5)]],
                                          constant float& metersToWorldZ [[buffer(6)]],
                                          depth2d_array<float> shadowMap [[texture(0)]]) {
    return shadeExtrudedFragment(in, shadow, metersToWorldZ, shadowMap);
}

// Framebuffer-fetch path (Apple GPUs): the same shading lands in the world
// pass's second, memoryless color attachment; color(0) is untouched (its
// write mask is empty in the pipeline), and the composite below reads the
// attachment back per sample without it ever leaving tile memory.
struct ExtrudedIntoImageFragmentOut {
    half4 image [[color(1)]];
};

fragment ExtrudedIntoImageFragmentOut tileExtrudedIntoImageFragmentShader(FragmentIn in [[stage_in]],
                                                                          constant Shadow& shadow [[buffer(5)]],
                                                                          constant float& metersToWorldZ [[buffer(6)]],
                                                                          depth2d_array<float> shadowMap [[texture(0)]]) {
    ExtrudedIntoImageFragmentOut out;
    out.image = shadeExtrudedFragment(in, shadow, metersToWorldZ, shadowMap);
    return out;
}

// Depth-only path of the shadow map pass. All cascades render in one pass:
// the geometry draws with instanceCount = cascade count, each instance
// projects through its cascade's light matrix and lands in the matching
// slice of the shadow texture array via [[render_target_array_index]].
struct ExtrudedShadowVertexOut {
    float4 position [[position]];
    float clipDistance [[clip_distance]] [4];
    uint layer [[render_target_array_index]];
};

vertex ExtrudedShadowVertexOut tileExtrudedShadowVertexShader(VertexIn vertexIn [[stage_in]],
                                                              uint instanceID [[instance_id]],
                                                              constant ShadowCasterMatrices& casters [[buffer(1)]],
                                                              constant float4x4& modelMatrix [[buffer(3)]],
                                          constant float4& localClipBounds [[buffer(4)]]) {
    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);
    ExtrudedShadowVertexOut out;
    out.position = casters.lightProjectionViews[instanceID] * worldPosition;
    writeLocalClipDistances(out.clipDistance, vertexIn.position.xy, localClipBounds);
    out.layer = instanceID;
    return out;
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
fragment half4 tileExtrudedCompositeFragmentShader(ExtrudedCompositeVertexOut in [[stage_in]],
                                                   texture2d<half, access::read> buildingImage [[texture(0)]],
                                                   constant float& alpha [[buffer(0)]]) {
    half4 premultiplied = buildingImage.read(uint2(in.position.xy));
    return premultiplied * half(alpha);
}

// Framebuffer-fetch composite: reads the in-pass building attachment per
// sample, entirely in tile memory, and blends it over the map with the same
// premultiplied factors as the two-pass path (per covered sample instead of
// per resolved pixel, which only differs where a building edge crosses a
// ground-color edge within one pixel). The far-plane depth output restores
// the pre-building depth: the pass clears depth to 1.0 and the flat surface
// writes none, so composited buildings keep not occluding the scene models,
// exactly like the two-pass path.
struct ExtrudedCompositeFetchFragmentOut {
    half4 color [[color(0)]];
    float depth [[depth(any)]];
};

fragment ExtrudedCompositeFetchFragmentOut tileExtrudedCompositeFetchFragmentShader(half4 image [[color(1)]],
                                                                                    constant float& alpha [[buffer(0)]]) {
    ExtrudedCompositeFetchFragmentOut out;
    out.color = image * half(alpha);
    out.depth = 1.0;
    return out;
}
