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
/// The exact rank depth: the fragment stage writes the layer's rank as a
/// constant ([[depth(any)]], tileExactDepthFragmentShader) instead of the
/// rasterizer interpolating it from the vertex z. The vertex band below
/// (out.position.z = layerNdcZ * w) is exact only until a triangle is cut
/// at the near plane: the clipper builds the cut vertex from the two ends
/// in float, and a vertex hundreds of world units away leaves an error of
/// its own magnitude times 2^-24 in a w of 0.01, which is thousands of rank
/// steps at the cut and still tens to thousands at the far pixels the
/// triangle reaches on screen. The base and the landcover of the horizon
/// backdrop (z0 cells of 64 tile units) then swap order from frame to
/// frame, a flicker that follows the camera, and a coarse band's layers
/// swap the same way at a smaller scale. A source whose triangles are
/// small against the near distance (the target zoom's tiles) keeps the
/// vertex band and the early depth test; every coarser source and the
/// backdrop take this variant (FlatMapSurfaceDrawer decides by zoom).
constant bool kTileExactRankDepth [[function_constant(3)]];
constant bool kSamplesShadowCascades = !kGroundShadowMaskEnabled;

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
// The camera's near plane in view units (RenderCamera.nearPlane, pinned
// by TileClipDistanceContractTests). The surface writes its depth as the
// rank band, not the projection's z, which leaves Metal's z clip with
// nothing to cut at the near plane: a triangle running behind the eye is
// then cut at the eye's own plane (w = 0) and its cut vertex projects to
// infinity, which the rasterizer resolves differently from frame to
// frame, blocks of the near ground dropping out at a street tilt on the
// deepest zoom. The near clip distance below cuts at the real plane. The
// cut vertex's depth is still the clipper's float arithmetic on the two
// ends, which is why large triangles take the exact rank depth instead
// (kTileExactRankDepth).
constant float kFlatCameraNearPlane = 0.01;
// The farthest a deferred ribbon's vertex moves, in tile units: a quarter
// of the tile, past which a width on screen is a camera at the vertex's
// own depth and the triangle only needs to stay finite.
constant float kTileDeferredRibbonMaximumUnits = 1024.0;

// lineStyle packs the per-style constants (edge threshold, width points,
// dash points, gap points); constant per primitive, so half is exact enough.
struct VertexOut {
    float4 position [[position]];
    // No slot clip distances: a retained substitute draws at full extent
    // and the tile-priority stencil rejects it wherever a finer tile
    // painted (TileSourceStencilPriority), the same mechanism the sphere
    // uses. The one clip distance below is the road distance cut.
    float3 worldPos;
    half4 color [[function_constant(kTileFillFields)]];
    // Lines classes: the style index rides flat and the fragment resolves
    // colour, fade and line style itself; only the two genuinely
    // per-vertex line fields interpolate (the longitudinal parameter raw,
    // its decode scale being a style constant).
    uint styleIndex [[flat, function_constant(kTileLineFields)]];
    float lineDistance [[function_constant(kTileLineFields)]];
    float lineParameterRaw [[function_constant(kTileLineFields)]];
    // A deferred ribbon's visible half-width in pixels, resolved here from
    // the style and the vertex's own scale on screen (the rim is extruded
    // one feather past it); zero for a pre-extruded ribbon.
    float deferredEdgePx [[flat, function_constant(kTileLineFields)]];
    // The ground direction a deferred ribbon's width is laid in: the
    // extrusion direction, interpolated, so across a fan it sweeps with the
    // rim and across a segment it keeps its axis (the sign flips through
    // the centreline, and only the axis is read). Zero where nothing is
    // deferred.
    float2 widthAxis [[function_constant(kTileLineFields)]];
    // The exact variant: the layer's rank depth, flat, written by the
    // fragment stage as the fragment's depth.
    float rankDepth [[flat, function_constant(kTileExactRankDepth)]];
    // One cut, not a slot clip (see above): the camera's near plane, which
    // the rank depth took away from the z clip (kFlatCameraNearPlane).
    float clipDistance [[clip_distance]] [1];
};

// The fragment stage's view of VertexOut: the same interpolants matched by
// name.
struct FragmentIn {
    float4 position [[position]];
    float3 worldPos;
    half4 color [[function_constant(kTileFillFields)]];
    uint styleIndex [[flat, function_constant(kTileLineFields)]];
    float lineDistance [[function_constant(kTileLineFields)]];
    float lineParameterRaw [[function_constant(kTileLineFields)]];
    float deferredEdgePx [[flat, function_constant(kTileLineFields)]];
    float2 widthAxis [[function_constant(kTileLineFields)]];
    float rankDepth [[flat, function_constant(kTileExactRankDepth)]];
};

/// The exact variant's output: the colour and the rank depth as the
/// fragment's depth, so the depth test compares the constant itself.
struct TileExactDepthFragmentOut {
    half4 color [[color(0)]];
    float depth [[depth(any)]];
};

vertex VertexOut tileVertexShader(VertexIn vertexIn [[stage_in]],
                                  constant Camera& camera [[buffer(1)]],
                                  constant Style* styles [[buffer(2)]],
                                  constant float4x4& modelMatrix [[buffer(3)]],
                                  constant float2* styleZoomFades [[buffer(4)]],
                                  constant LineStyle* lineStyles [[buffer(5)]],
                                  constant float& depthBandOffset [[buffer(7)]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(8)]]) {
    float2 localPosition = float2(vertexIn.position.xy);
    float deferredEdgePx = 0.0;
    float2 widthAxis = float2(0.0);
    if (kTileLineFields) {
        // A deferred ribbon: the vertex is a point of the centreline and
        // carries the direction to extrude along. The style's width is
        // resolved in pixels right here, from how many pixels one tile
        // unit spans at this vertex (the clip-space span of the direction,
        // divided out by the perspective), and the vertex moves out by
        // that plus the feather, in tile units. So the ribbon is as wide
        // on screen as the style says at every distance, a stroke's floor
        // holds in pixels to the horizon, and no ribbon is ever a sliver
        // thinner than a pixel for the rasterizer to hit and miss.
        float2 normal = vertexIn.normal;
        if (dot(normal, normal) > 0.25) {
            normal = normalize(normal);
            widthAxis = normal;
            LineStyle lineStyle = lineStyles[vertexIn.styleIndex];
            float4 clipCentre = camera.matrix * (modelMatrix * float4(localPosition, 0.0, 1.0));
            float4 clipAlong = camera.matrix * (modelMatrix * float4(normal, 0.0, 0.0));
            // Behind the near plane the span is meaningless: the depths are
            // floored so the width stays finite there. The vertex is cut,
            // but it still shapes its triangles (see the ground width
            // below), so only the feather may come from the span.
            float w0 = max(clipCentre.w, kFlatCameraNearPlane);
            float w1 = max(clipCentre.w + clipAlong.w, kFlatCameraNearPlane);
            float2 screenSpan = ((clipCentre.xy + clipAlong.xy) / w1 - clipCentre.xy / w0)
                * overviewFade.viewportSizePx * 0.5;
            float pixelsPerUnit = max(length(screenSpan), 1e-4);
            deferredEdgePx = tileLineEdgePixels(lineStyle, pixelsPerUnit,
                                                overviewFade.pixelsPerPoint, overviewFade.cameraZoom);
            float units;
            if (lineStyle.widthPoints > 0.0
                && overviewFade.pointWidthReferenceDepth > 0.0
                && overviewFade.pointWidthCentrePixelsPerWorldUnit > 0.0) {
                // A point-locked width lies on the ground
                // (tilePointWidthPerspectiveScale): one ground half-width
                // per style, the same at every vertex of every ribbon of
                // it, so the rim is stated as that width directly, the
                // pixels at the centre of the screen over the pixels a
                // world unit spans there, in tile units through the
                // model's scale. The fragment stage scales the flat
                // unscaled width by its own depth and direction, so the
                // edge is exact per pixel whatever depth range the
                // triangle spans. Resolving the rim through the screen
                // span gives the same number for a vertex in front of the
                // camera and a meaningless one for a vertex behind the
                // near plane, whose screen point is nowhere. That vertex
                // is cut, but it still shapes its triangles: a ribbon
                // extruded wider at one row than at the other is a
                // trapezoid, and the distance field a trapezoid cut into
                // two triangles interpolates bends at the diagonal, so the
                // visible part of every segment that began behind the
                // camera drew veering off its centreline, by more the
                // closer it came, the whole road swinging with the
                // camera's bearing (a straight bridge kinked at the tile
                // seam under a street tilt).
                float unitsPerWorld = 1.0 / max(length(modelMatrix[0].xyz), 1e-9);
                units = deferredEdgePx / overviewFade.pointWidthCentrePixelsPerWorldUnit * unitsPerWorld;
            } else {
                // A width on screen: the rim moves by the width at this
                // vertex's own scale.
                float rimEdgePx = deferredEdgePx;
                if (lineStyle.widthPoints > 0.0) {
                    rimEdgePx *= tilePointWidthPerspectiveScale(overviewFade, w0, normal, clipCentre.xy / w0);
                }
                units = rimEdgePx / pixelsPerUnit;
            }
            // The feather at this vertex's scale on screen. Behind the
            // near plane the floored span is far too many pixels a unit
            // and the feather vanishes, which the cut vertex never shows.
            units = min(units + kTileDeferredRibbonFeatherPx / pixelsPerUnit,
                        kTileDeferredRibbonMaximumUnits);
            localPosition += normal * units;
        }
    }
    float4 worldPosition = modelMatrix * float4(localPosition, 0.0, 1.0);

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
    if (kTileExactRankDepth) {
        out.rankDepth = layerNdcZ;
    }
    out.worldPos = worldPosition.xyz;
    // The near plane, in the clip space w (the view depth): what the z clip
    // would have cut had z been the projection's.
    out.clipDistance[0] = out.position.w - kFlatCameraNearPlane;
    if (kTileLineFields) {
        out.styleIndex = uint(vertexIn.styleIndex);
        out.lineDistance = float(vertexIn.lineDistance) / 127.0;
        out.lineParameterRaw = float(vertexIn.lineParameter);
        out.deferredEdgePx = deferredEdgePx;
        out.widthAxis = widthAxis;
    } else {
        TileVertexStyle style = tileVertexStyle(vertexIn, styles, styleZoomFades, lineStyles);
        out.color = style.color;
        // The zoom fade folds into the alpha here: a function of the style
        // and the frame only, so the fills fragment neither interpolates
        // the mask nor walks the fade bands.
        out.color.a *= tileStyleFade(style.zoomFade, overviewFade);
    }
    return out;
}

/// The point-locked width of a deferred ribbon at this pixel's depth (the
/// vertex stage moved the rim by the same rule). `position.w` is one over
/// the view depth.
static inline float tileFragmentDeferredEdgePx(FragmentIn in,
                                               constant LineStyle* lineStyles,
                                               constant OverviewFadeUniform& overviewFade) {
    float deferredEdgePx = in.deferredEdgePx;
    if (deferredEdgePx > 0.0 && lineStyles[in.styleIndex].widthPoints > 0.0) {
        // The pixel's place on screen in NDC, y up.
        float2 ndc = in.position.xy / max(overviewFade.viewportSizePx, float2(1.0)) * float2(2.0, -2.0)
            + float2(-1.0, 1.0);
        deferredEdgePx *= tilePointWidthPerspectiveScale(overviewFade,
                                                         1.0 / max(in.position.w, 1e-6),
                                                         in.widthAxis,
                                                         ndc);
    }
    return deferredEdgePx;
}

// Nothing here discards: a retained substitute is kept out of covered
// slots by the tile-priority stencil test (early, before shading), so the
// GPU can resolve visibility before the fragment runs. The body is shared
// by the two entries below: the plain one returns the colour and leaves
// the depth to the rasterizer, the exact one writes the rank depth too.
static inline half4 tileFragmentColor(FragmentIn in,
                                      constant OverviewFadeUniform& overviewFade,
                                      constant Shadow& shadow,
                                      constant LineDashUniform& lineDash,
                                      constant Style* styles,
                                      constant float2* styleZoomFades,
                                      constant LineStyle* lineStyles,
                                      depth2d<float> shadowMap,
                                      texture2d<half> groundShadowMask) {
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
        float deferredEdgePx = tileFragmentDeferredEdgePx(in, lineStyles, overviewFade);
        color = tileLineFragmentColor(in.styleIndex, in.lineDistance, in.lineParameterRaw,
                                      styles, styleZoomFades, lineStyles,
                                      overviewFade, lineDash, deferredEdgePx);
    } else {
        color = in.color;
    }
    // Zero normal (passed above): the ground always faces the sun and
    // keeps its tight contact (no normal-offset shift).
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    return color;
}

fragment half4 tileFragmentShader(FragmentIn in [[stage_in]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                  constant Shadow& shadow [[buffer(3)]],
                                  constant LineDashUniform& lineDash [[buffer(4)]],
                                  constant Style* styles [[buffer(5), function_constant(kTileLineFields)]],
                                  constant float2* styleZoomFades [[buffer(6), function_constant(kTileLineFields)]],
                                  constant LineStyle* lineStyles [[buffer(7), function_constant(kTileLineFields)]],
                                  depth2d<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
                                  texture2d<half> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]) {
    return tileFragmentColor(in, overviewFade, shadow, lineDash, styles, styleZoomFades, lineStyles,
                             shadowMap, groundShadowMask);
}

// The exact rank depth (kTileExactRankDepth): the same colour, and the
// layer's rank written as the fragment's depth, a constant per style that
// no clipping or interpolation can move. Costs the early depth and stencil
// tests of its draws, which is why only the sources whose triangles are
// too large for the vertex band use it.
fragment TileExactDepthFragmentOut tileExactDepthFragmentShader(FragmentIn in [[stage_in]],
                                                                constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                                                constant Shadow& shadow [[buffer(3)]],
                                                                constant LineDashUniform& lineDash [[buffer(4)]],
                                                                constant Style* styles [[buffer(5), function_constant(kTileLineFields)]],
                                                                constant float2* styleZoomFades [[buffer(6), function_constant(kTileLineFields)]],
                                                                constant LineStyle* lineStyles [[buffer(7), function_constant(kTileLineFields)]],
                                                                depth2d<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
                                                                texture2d<half> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]) {
    TileExactDepthFragmentOut out;
    out.color = tileFragmentColor(in, overviewFade, shadow, lineDash, styles, styleZoomFades, lineStyles,
                                  shadowMap, groundShadowMask);
    out.depth = in.rankDepth;
    return out;
}

// The road sheet: the roads drawn as one sheet, every pixel blended once,
// whatever overlaps there: the segments and the join fan of a bend, two
// streets at a junction, a flyover across the road under it, the stitching
// margins of two tiles, a cap over the next piece. A translucent road (a
// tunnel, a translucent theme colour) otherwise composites twice in every
// overlap and stamps a darker
// patch there. A sheet is one role of the roads that read as one network
// (FlatMapSurfaceDrawer decides: the carriageways of the ground and of the
// bridges together, whatever their class).
//
// Two draws per sheet over the same geometry, both writing the fragment's
// depth as a constant. A fragment inside a ribbon's body (full coverage)
// takes a rank in the sheet's band from its alpha, the more opaque the
// nearer, a fragment of the antialiasing fringe takes the band's far end,
// and a fragment outside the visible line takes the far plane, which fails
// every test.
// - The depth stage (no colour) writes the nearest body rank per pixel, so
//   the pixel belongs to the most opaque road that covers it with a body:
//   a faded side street never punches a lighter hole in the avenue it
//   meets, and a fringe never takes a pixel from the body of another road.
// - The colour stage tests lessEqual without writing, one rank nearer than
//   its alpha says, so the two stages, compiled apart, may round an alpha
//   to neighbouring ranks and the pixel's owner still draws. A fringe draws
//   only where no body of the sheet is. The sheet's stencil bit lets one
//   fragment through per pixel (TileSourceStencilPriority.roadSheetBit),
//   which settles equal and neighbouring ranks.
// Every depth is an integer count of power-of-two steps under a base that
// is a multiple of the step, so both stages compute the same bits.
struct RoadSheetUniform {
    // The far end of the sheet's band: the fringe's depth in the colour
    // stage.
    float baseDepth;
    float depthStep;
    // What a fringe fragment writes: the base in the colour stage, the far
    // plane in the depth stage, where a fringe claims nothing.
    float fringeDepth;
    // The alpha ranks of the band: an alpha of one is this rank.
    float maximumRank;
    // The coverage a fragment is a body from. The depth stage asks for a
    // little more than the colour stage, so a fragment the two stages round
    // differently at the threshold is a body in the colour stage whenever
    // it was one in the depth stage, and never a hole in its own road.
    float bodyCoverage;
    // The ranks the colour stage tests nearer than its alpha says: zero in
    // the depth stage, one in the colour stage.
    float rankBias;
};

/// A road fragment's alpha apart from its coverage: the style's and the
/// zoom fades, the factors tileFragmentColor applies.
static inline float tileRoadSheetAlpha(FragmentIn in,
                                       constant Style* styles,
                                       constant float2* styleZoomFades,
                                       constant LineStyle* lineStyles,
                                       constant OverviewFadeUniform& overviewFade,
                                       float deferredEdgePx) {
    float alpha = styles[in.styleIndex].color.a
        * float(tileStyleFade(styleZoomFades[in.styleIndex], overviewFade))
        * tilePointWidthRampAlpha(lineStyles[in.styleIndex], overviewFade.cameraZoom);
    return clamp(alpha, 0.0, 1.0);
}

static inline float tileRoadSheetDepth(half coverage, float alpha, constant RoadSheetUniform& roadSheet) {
    if (float(coverage) >= roadSheet.bodyCoverage) {
        float rank = floor(alpha * roadSheet.maximumRank) + 1.0 + roadSheet.rankBias;
        return roadSheet.baseDepth - rank * roadSheet.depthStep;
    }
    return coverage > 0.001h ? roadSheet.fringeDepth : 1.0;
}

struct TileRoadSheetDepthOut {
    float depth [[depth(any)]];
};

fragment TileRoadSheetDepthOut tileRoadSheetDepthFragmentShader(FragmentIn in [[stage_in]],
                                                                constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                                                constant LineDashUniform& lineDash [[buffer(4)]],
                                                                constant Style* styles [[buffer(5)]],
                                                                constant float2* styleZoomFades [[buffer(6)]],
                                                                constant LineStyle* lineStyles [[buffer(7)]],
                                                                constant RoadSheetUniform& roadSheet [[buffer(11)]]) {
    float deferredEdgePx = tileFragmentDeferredEdgePx(in, lineStyles, overviewFade);
    half coverage = tileLineFragmentCoverage(in.styleIndex, in.lineDistance, in.lineParameterRaw,
                                             lineStyles, overviewFade, lineDash, deferredEdgePx);
    float alpha = tileRoadSheetAlpha(in, styles, styleZoomFades, lineStyles, overviewFade, deferredEdgePx);
    TileRoadSheetDepthOut out;
    out.depth = tileRoadSheetDepth(coverage, alpha, roadSheet);
    return out;
}

fragment TileExactDepthFragmentOut tileRoadSheetFragmentShader(FragmentIn in [[stage_in]],
                                                               constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                                               constant Shadow& shadow [[buffer(3)]],
                                                               constant LineDashUniform& lineDash [[buffer(4)]],
                                                               constant Style* styles [[buffer(5)]],
                                                               constant float2* styleZoomFades [[buffer(6)]],
                                                               constant LineStyle* lineStyles [[buffer(7)]],
                                                               constant RoadSheetUniform& roadSheet [[buffer(11)]],
                                                               depth2d<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
                                                               texture2d<half> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]) {
    float deferredEdgePx = tileFragmentDeferredEdgePx(in, lineStyles, overviewFade);
    half coverage = tileLineFragmentCoverage(in.styleIndex, in.lineDistance, in.lineParameterRaw,
                                             lineStyles, overviewFade, lineDash, deferredEdgePx);
    float alpha = tileRoadSheetAlpha(in, styles, styleZoomFades, lineStyles, overviewFade, deferredEdgePx);
    TileExactDepthFragmentOut out;
    out.color = tileFragmentColor(in, overviewFade, shadow, lineDash, styles, styleZoomFades, lineStyles,
                                  shadowMap, groundShadowMask);
    out.depth = tileRoadSheetDepth(coverage, alpha, roadSheet);
    return out;
}
