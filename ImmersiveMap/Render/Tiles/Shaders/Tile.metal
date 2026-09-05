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
/// The fills classes carry the resolved colour; the lines classes carry the
/// flat style index and the fragment resolves the style itself
/// (tileLineFragmentColor), cutting a line vertex's interpolants to a third.
constant bool kTileFillFields = !kTileLineFields;
/// The fill-outline variant of the fills class: the fill's ring edges drawn
/// as one-pixel LINE primitives in the fill's colour, alpha by the
/// fragment's distance to the projected edge (the fill-antialias
/// construction of Mapbox GL). It softens the staircase the triangle
/// rasterizer leaves on every fill edge, and under camera motion the
/// fringe's alpha slides continuously instead of the edge jumping a pixel.
/// Line fields never accompany it (a line primitive has no ribbon field).
constant bool kTileFillOutline [[function_constant(2)]];
constant bool kSamplesShadowCascades = !kGroundShadowMaskEnabled;

/// The drawable size in pixels, what the outline needs to place the
/// interpolated clip position in the fragment's pixel space.
struct FillOutlineUniform {
    float2 viewportSizePx;
};
// Mask pixels per drawable pixel; mirrors
// GroundShadowMaskPipeline.resolutionScale. The mask is sampled bilinearly
// at the pixel's position scaled by this, so a half-size mask upsamples
// smoothly instead of blocking.
constant float kGroundShadowMaskScale = 0.4;

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
    half4 color [[function_constant(kTileFillFields)]];
    // The footprint fade target with its strength in the alpha, palette
    // blended like the colour (flat: one value per style).
    half4 farColor [[flat, function_constant(kTileFillFields)]];
    // Lines classes: the style index rides flat and the fragment resolves
    // colour, fade and line style itself; only the two genuinely
    // per-vertex line fields interpolate (the longitudinal parameter raw,
    // its decode scale being a style constant).
    uint styleIndex [[flat, function_constant(kTileLineFields)]];
    float lineDistance [[function_constant(kTileLineFields)]];
    float lineParameterRaw [[function_constant(kTileLineFields)]];
    // The outline variant carries the clip position once more, as an
    // ordinary (perspective-correct) interpolant: divided by w in the
    // fragment it is the point of the projected edge the rasterizer paired
    // with this fragment, and unlike a screen position computed per vertex
    // it survives a segment clipped by the near plane.
    float4 clipPosition [[function_constant(kTileFillOutline)]];
};

// The fragment stage's view of VertexOut: the same interpolants matched by
// name.
struct FragmentIn {
    float4 position [[position]];
    float3 worldPos;
    half4 color [[function_constant(kTileFillFields)]];
    half4 farColor [[flat, function_constant(kTileFillFields)]];
    uint styleIndex [[flat, function_constant(kTileLineFields)]];
    float lineDistance [[function_constant(kTileLineFields)]];
    float lineParameterRaw [[function_constant(kTileLineFields)]];
    float4 clipPosition [[function_constant(kTileFillOutline)]];
};

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
    if (kTileFillOutline) {
        out.clipPosition = out.position;
    }
    if (kTileLineFields) {
        out.styleIndex = uint(vertexIn.styleIndex);
        out.lineDistance = float(vertexIn.lineDistance) / 127.0;
        out.lineParameterRaw = float(vertexIn.lineParameter);
    } else {
        TileVertexStyle style = tileVertexStyle(vertexIn, styles, lowZoomFadeMasks,
                                                lineStyles, streetPalette);
        out.color = style.color;
        // The zoom fade folds into the alpha here: a function of the style
        // and the frame only, so the fills fragment neither interpolates
        // the mask nor walks the fade bands.
        out.color.a *= tileStyleFade(style.lowZoomFadeMask, overviewFade);
        Style rawStyle = styles[vertexIn.styleIndex];
        out.farColor = half4(mix(rawStyle.farColor, rawStyle.farStreetColor, streetPalette.blend));
    }
    return out;
}

// Nothing here discards: a retained substitute is kept out of covered
// slots by the tile-priority stencil test (early, before shading), so the
// GPU can resolve visibility before the fragment runs.
fragment half4 tileFragmentShader(FragmentIn in [[stage_in]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                  constant Shadow& shadow [[buffer(3)]],
                                  constant LineDashUniform& lineDash [[buffer(4)]],
                                  constant Style* styles [[buffer(5), function_constant(kTileLineFields)]],
                                  constant float* lowZoomFadeMasks [[buffer(6), function_constant(kTileLineFields)]],
                                  constant LineStyle* lineStyles [[buffer(7), function_constant(kTileLineFields)]],
                                  constant StreetPaletteUniform& streetPalette [[buffer(8), function_constant(kTileLineFields)]],
                                  constant FillOutlineUniform& fillOutline [[buffer(9), function_constant(kTileFillOutline)]],
                                  constant FootprintFadeUniform& footprintFade [[buffer(10), function_constant(kTileFillFields)]],
                                  depth2d<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
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
    // The lines classes resolve colour, fade and coverage from the flat
    // style index right here.
    half4 color;
    if (kTileLineFields) {
        color = tileLineFragmentColor(in.styleIndex, in.lineDistance, in.lineParameterRaw,
                                      styles, lowZoomFadeMasks, lineStyles, streetPalette,
                                      overviewFade, lineDash);
    } else {
        color = in.color;
        // The footprint fade: where this pixel covers more of the source
        // tile than the fill's detail resolves (a tilted far range, a
        // coarse tile minified), the colour converges on the style's far
        // tone at the style's strength, so the blotches that flickered
        // between samples become one plain. The derivatives are taken here,
        // in uniform flow, before the outline branch.
        float fade = tileFootprintFadeAmount(in.worldPos, footprintFade);
        color.rgb = mix(color.rgb, in.farColor.rgb, half(fade) * in.farColor.a);
        if (kTileFillOutline) {
            // A fill too thin for a pixel would still draw its outline as a
            // hairline the full width of the fill; past the fade the
            // outline goes with the detail it was antialiasing.
            color.a *= half(1.0 - fade);
        }
    }
    if (kTileFillOutline) {
        // The projected edge point paired with this fragment, in pixels of
        // the drawable (origin top-left, like [[position]]), and its
        // distance to the fragment centre: zero when the edge runs through
        // the centre, about half a pixel when it grazes the pixel's side.
        // The one-pixel line covers only the pixels along the edge, so the
        // ramp is the edge's fringe: full colour on the edge, half a pixel
        // out it is half, and the fill's own interior underneath is the
        // same colour, so only the outside fringe is what shows.
        float2 edgeNdc = in.clipPosition.xy / in.clipPosition.w;
        float2 edgePx = (edgeNdc * float2(0.5, -0.5) + 0.5) * fillOutline.viewportSizePx;
        float edgeDistancePx = length(edgePx - in.position.xy);
        color.a *= half(1.0 - smoothstep(0.0, 1.0, edgeDistancePx));
    }
    // Zero normal (passed above): the ground always faces the sun and
    // keeps its tight contact (no normal-offset shift).
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    return color;
}
