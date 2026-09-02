// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "TileShading.h"

// Ground shadow source. The flat world pass reads the per-pixel ground
// shadow mask (GroundShadowMask.metal), evaluated once per frame for the
// plane every blended ground layer lies on; the globe atlas bake, which never
// has shadows, keeps the direct cascade sampling path and binds a disabled
// uniform. A function constant so each pipeline only declares the texture it
// reads (the other argument is compiled out and needs no binding).
constant bool kGroundShadowMaskEnabled [[function_constant(0)]];

/// True when the pass carries the analytic line fields (the ribbons class,
/// the road buckets and the bridge overlay); the fills classes drop them,
/// exactly like the sphere's variants: no export, no interpolation, and a
/// fragment that is the colour as is.
constant bool kTileLineFields [[function_constant(1)]];
constant bool kSamplesShadowCascades = !kGroundShadowMaskEnabled;
// Mask pixels per drawable pixel; mirrors
// GroundShadowMaskPipeline.resolutionScale. The mask is sampled bilinearly
// at the pixel's position scaled by this, so a half-size mask upsamples
// smoothly instead of blocking.
constant float kGroundShadowMaskScale = 0.5;

// color and the fade mask are unit-range, so they interpolate as half: fewer
// interpolant registers and double-rate ALU on A-series GPUs (the same split
// the starfield shader uses). Positions stay float.
// The line distances stay float: the antialiasing band can be a small
// fraction of the normalized field on wide lines, below half's precision
// near 1.0, and the arc parameter spans thousands of tile units.
// The flat rank-depth step, one value with the sphere's
// (kTileSphereLayerDepthStep; mirrored by GlobeSurfaceDepthRank and pinned
// by TileClipDistanceContractTests).
constant float kFlatTileLayerDepthStep = 4e-7;

// lineStyle packs the per-style constants (edge threshold, width points,
// dash points, gap points); constant per primitive, so half is exact enough.
struct VertexOut {
    float4 position [[position]];
    // No slot clip distances: a retained substitute draws at full extent
    // and the tile-priority stencil rejects it wherever a finer tile
    // painted (TileSourceStencilPriority), the same mechanism the sphere
    // uses.
    float3 worldPos;
    half4 color;
    float lineDistance [[function_constant(kTileLineFields)]];
    float lineParameter [[function_constant(kTileLineFields)]];
    half4 lineStyle [[function_constant(kTileLineFields)]];
    half lineMinimumWidthPoints [[function_constant(kTileLineFields)]];
    half lineMaximumWidthPoints [[function_constant(kTileLineFields)]];
    // 1 when the dash pattern is already in tile units (world-locked paint),
    // 0 when it is in points and scales by the draw's unitsPerPoint.
    half lineDashInTileUnits [[function_constant(kTileLineFields)]];
};

// The fragment stage's view of VertexOut: the same interpolants matched by
// name.
struct FragmentIn {
    float4 position [[position]];
    float3 worldPos;
    half4 color;
    float lineDistance [[function_constant(kTileLineFields)]];
    float lineParameter [[function_constant(kTileLineFields)]];
    half4 lineStyle [[function_constant(kTileLineFields)]];
    half lineMinimumWidthPoints [[function_constant(kTileLineFields)]];
    half lineMaximumWidthPoints [[function_constant(kTileLineFields)]];
    half lineDashInTileUnits [[function_constant(kTileLineFields)]];
};

static inline TileVertexStyle tileFragmentStyle(FragmentIn in) {
    TileVertexStyle style;
    style.color = in.color;
    // The fade is already in the alpha; the member is dead here.
    style.lowZoomFadeMask = 0.0h;
    style.lineDistance = in.lineDistance;
    style.lineParameter = in.lineParameter;
    style.lineStyle = in.lineStyle;
    style.lineMinimumWidthPoints = in.lineMinimumWidthPoints;
    style.lineMaximumWidthPoints = in.lineMaximumWidthPoints;
    style.lineDashInTileUnits = in.lineDashInTileUnits;
    return style;
}

vertex VertexOut tileVertexShader(VertexIn vertexIn [[stage_in]],
                                  constant Camera& camera [[buffer(1)]],
                                  constant Style* styles [[buffer(2)]],
                                  constant float4x4& modelMatrix [[buffer(3)]],
                                  constant float* lowZoomFadeMasks [[buffer(4)]],
                                  constant LineStyle* lineStyles [[buffer(5)]],
                                  constant StreetPaletteUniform& streetPalette [[buffer(6)]],
                                  constant float& depthBandOffset [[buffer(7)]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(8)]]) {
    float4 worldPosition = modelMatrix * float4(float2(vertexIn.position.xy), 0.0, 1.0);

    VertexOut out;
    out.position = camera.matrix * worldPosition;
    // The flat surface carries no geometric depth of its own (every layer
    // lies on one plane): its z is the layer rank in a band at the far
    // plane, like the sphere's, so the opaque fill layers can draw under a
    // depth write and a pixel is shaded once by its topmost opaque layer,
    // while the whole band stays farther than every real fragment and the
    // buildings' depth test keeps working unchanged. The per-draw offset
    // places the group: ground fills at 0, ground ribbons one class band
    // nearer, the road buckets and the bridge overlay nearer still
    // (GlobeSurfaceDepthRank mirrors the constants).
    float layerNdcZ = 1.0 - depthBandOffset
        - (float(vertexIn.styleIndex) + 1.0) * kFlatTileLayerDepthStep;
    out.position.z = layerNdcZ * out.position.w;
    out.worldPos = worldPosition.xyz;
    TileVertexStyle style = tileVertexStyle(vertexIn, styles, lowZoomFadeMasks, lineStyles, streetPalette);
    out.color = style.color;
    // The zoom fade folds into the alpha here: a function of the style and
    // the frame only, so the fragment neither interpolates the mask nor
    // walks the fade bands.
    out.color.a *= tileStyleFade(style.lowZoomFadeMask, overviewFade);
    if (kTileLineFields) {
        out.lineDistance = style.lineDistance;
        out.lineParameter = style.lineParameter;
        out.lineStyle = style.lineStyle;
        out.lineMinimumWidthPoints = style.lineMinimumWidthPoints;
        out.lineMaximumWidthPoints = style.lineMaximumWidthPoints;
        out.lineDashInTileUnits = style.lineDashInTileUnits;
    }
    return out;
}

// Nothing here discards: a retained substitute is kept out of covered
// slots by the tile-priority stencil test (early, before shading), so the
// GPU can resolve visibility before the fragment runs.
fragment half4 tileFragmentShader(FragmentIn in [[stage_in]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                  constant HorizonFog& horizonFog [[buffer(2)]],
                                  constant Shadow& shadow [[buffer(3)]],
                                  constant LineDashUniform& lineDash [[buffer(4)]],
                                  depth2d_array<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
                                  texture2d<half> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]) {
    float shadowFactor;
    if (kGroundShadowMaskEnabled) {
        // One bilinear tap of the mask instead of a cascade lookup in every
        // ground layer; the strength guard mirrors sampleShadowFactor's, so a
        // frame without the mask pass (shadows off, no casters) never samples
        // the 1x1 fallback.
        constexpr sampler maskSampler(coord::pixel, filter::linear, address::clamp_to_edge);
        shadowFactor = shadow.strength > 0.0
            ? float(groundShadowMask.sample(maskSampler, in.position.xy * kGroundShadowMaskScale).r)
            : 1.0;
    } else {
        shadowFactor = sampleShadowFactor(shadow, shadowMap, in.worldPos, float3(0.0));
    }
    // The fills classes carry no line fields: their coverage is identically
    // 1 and the colour (fade already folded in the vertex stage) is final.
    half4 color;
    if (kTileLineFields) {
        color = tileGroundColor(tileFragmentStyle(in), overviewFade, lineDash);
    } else {
        color = in.color;
    }
    // Shadow before fog: fog wins at distance, so the shadow-coverage edge
    // dissolves into the haze instead of cutting a visible line. Zero normal
    // (passed above): the ground always faces the sun and keeps its tight
    // contact (no normal-offset shift).
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    color.rgb = applyHorizonFog(color.rgb, horizonFog, in.worldPos);
    return color;
}
