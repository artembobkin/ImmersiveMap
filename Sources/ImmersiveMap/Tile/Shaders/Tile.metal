// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "TileShading.h"
#include "../../Render/Shaders/Shared/GroundFog.h"

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
/// The rank depth rides in the vertex z as a scale of the projection's z
/// (out.position.z *= layerDepthScale / kFlatRealDepthScale): the depth
/// stays the ground plane's, perspective-correct under any blow-up of a
/// tile, the hardware clips at the real near plane, and a layer's rank is
/// a per-pixel scale, the same for every layer at a pixel, so the ranks
/// order the layers at every distance (FlatGroundStreetTiltOffscreenRenderTests).
/// The road ribbons: the road buckets of a tile whose ribbons are deferred
/// (the centreline and a direction, extruded right here). The vertex stage
/// puts the rim exactly on the style's edge, so the geometry is the road
/// and the fragment stage computes no coverage: the edge is hard. The
/// style's colour, with its fades folded into the alpha, rides from the
/// vertex stage, and the depth is the road's rank in its band
/// (RoadRankDepth), which is what orders the roads, not the order they are
/// drawn in. A lines class like every ribbon (kTileLineFields is set too).
constant bool kTileRoadRibbons [[function_constant(4)]];
/// The road ribbons that are not opaque this frame: a translucent colour, a
/// fade under way, a dash pattern. Blended, with the gaps of a dashed style
/// discarded. Without it a road ribbon is opaque: no blending, no discard,
/// so the GPU resolves which road owns a pixel before it shades one.
constant bool kTileRoadBlended [[function_constant(5)]];
/// What each variant carries to its fragment stage: the resolved colour
/// (the fills and the roads), the fields of the analytic coverage (every
/// ribbon but a road), and the style index with the arc length (every
/// ribbon that may cut a dash pattern).
constant bool kTileColorField = kTileFillFields || kTileRoadRibbons;
constant bool kTileCoverageFields = kTileLineFields && !kTileRoadRibbons;
constant bool kTileStyleIndexField = kTileLineFields && (!kTileRoadRibbons || kTileRoadBlended);
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
constant float kFlatTileLayerDepthStep = 3.2e-6;
// The place of a draw in the rank-depth band (FlatMapSurfaceDrawer, buffer
// 7): the group's offset, and the step from one style rank to the next,
// kFlatTileLayerDepthStep for the layered ground and 0 for a flattened
// ground, whose fills overlap nowhere and all take the band's first step.
struct FlatDepthBand {
    float offset;
    float rankStep;
};
// The camera's near plane in view units (RenderCamera.nearPlane, pinned
// by TileClipDistanceContractTests). The surface writes its depth as the
// rank band, not the projection's z, which leaves Metal's z clip with
// nothing to cut at the near plane: a triangle running behind the eye is
// then cut at the eye's own plane (w = 0) and its cut vertex projects to
// infinity, which the rasterizer resolves differently from frame to
// frame, blocks of the near ground dropping out at a street tilt on the
// deepest zoom.
constant float kFlatCameraNearPlane = 0.01;
// The scale the camera's projection applies to the z of everything real
// (RenderCamera.realDepthScale, pinned by TileClipDistanceContractTests):
// the ground divides it out and applies its own layer's scale, 1 minus
// the layer's rank depth, so a wall is nearer than every ground layer by
// at least one step at every pixel, and the ground never covers its base.
constant float kFlatRealDepthScale = 1.0 - 1536.0 * kFlatTileLayerDepthStep;
// The farthest a deferred ribbon's vertex moves, in tile units: a quarter
// of the tile, past which a width on screen is a camera at the vertex's
// own depth and the triangle only needs to stay finite.
constant float kTileDeferredRibbonMaximumUnits = 1024.0;
// The narrowest a road ribbon is extruded, in pixels from the centreline:
// half a pixel a side, so a road far down a tilted view is still a pixel
// wide for the rasterizer to hit in every row, instead of a sliver it hits
// and misses.
constant float kTileRoadMinimumHalfWidthPx = 0.5;
// The style ranks of one road band (RoadRankDepth.ranksPerBand, pinned by
// RoadRankDepthContractTests): a style past the last rank shares it.
constant float kTileRoadBandRanks = 12.0;

// lineStyle packs the per-style constants (edge threshold, width points,
// dash points, gap points); constant per primitive, so half is exact enough.
struct VertexOut {
    float4 position [[position]];
    // No slot clip distances: a retained substitute draws at full extent
    // and the tile-priority stencil rejects it wherever a finer tile
    // painted (TileSourceStencilPriority), the same mechanism the sphere
    // uses. The one clip distance below is the road distance cut.
    float3 worldPos;
    half4 color [[function_constant(kTileColorField)]];
    // Lines classes: the style index rides flat and the fragment resolves
    // colour, fade and line style itself; only the two genuinely
    // per-vertex line fields interpolate (the longitudinal parameter raw,
    // its decode scale being a style constant). A road ribbon carries the
    // index and the parameter only where it may cut a dash pattern.
    uint styleIndex [[flat, function_constant(kTileStyleIndexField)]];
    float lineDistance [[function_constant(kTileCoverageFields)]];
    float lineParameterRaw [[function_constant(kTileStyleIndexField)]];
    // A deferred ribbon's visible half-width in pixels, resolved here from
    // the style and the vertex's own scale on screen (the rim is extruded
    // one feather past it); zero for a pre-extruded ribbon.
    float deferredEdgePx [[flat, function_constant(kTileCoverageFields)]];
    // The ground direction a deferred ribbon's width is laid in: the
    // extrusion direction, interpolated, so across a fan it sweeps with the
    // rim and across a segment it keeps its axis (the sign flips through
    // the centreline, and only the axis is read). Zero where nothing is
    // deferred.
    float2 widthAxis [[function_constant(kTileCoverageFields)]];
    // No slot clip (see above) and no near cut: the depth is the
    // projection's, so the hardware clips at the near plane. The one use
    // is a road ribbon invisible this frame, cut whole.
    float clipDistance [[clip_distance]] [1];
};

// The fragment stage's view of VertexOut: the same interpolants matched by
// name.
struct FragmentIn {
    float4 position [[position]];
    float3 worldPos;
    half4 color [[function_constant(kTileColorField)]];
    uint styleIndex [[flat, function_constant(kTileStyleIndexField)]];
    float lineDistance [[function_constant(kTileCoverageFields)]];
    float lineParameterRaw [[function_constant(kTileStyleIndexField)]];
    float deferredEdgePx [[flat, function_constant(kTileCoverageFields)]];
    float2 widthAxis [[function_constant(kTileCoverageFields)]];
};

vertex VertexOut tileVertexShader(VertexIn vertexIn [[stage_in]],
                                  constant Camera& camera [[buffer(1)]],
                                  constant Style* styles [[buffer(2)]],
                                  constant float4x4& modelMatrix [[buffer(3)]],
                                  constant float2* styleZoomFades [[buffer(4)]],
                                  constant LineStyle* lineStyles [[buffer(5)]],
                                  constant FlatDepthBand& depthBand [[buffer(7)]],
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
            // The pixels a unit spans at this depth whatever the direction:
            // the across-the-view scale at the screen centre, brought to
            // this depth. The span of the direction is nothing for a vertex
            // behind the near plane, whose screen point is nowhere, and a
            // floor or a feather stated in pixels over it would push the
            // rim a quarter tile out (kTileDeferredRibbonMaximumUnits),
            // which distorts the visible part of every triangle the vertex
            // shapes. The width itself keeps the span: a width in pixels
            // over it cancels back to units, and a point width never
            // reads it.
            float isotropicPixelsPerUnit = pixelsPerUnit;
            if (overviewFade.pointWidthReferenceDepth > 0.0
                && overviewFade.pointWidthCentrePixelsPerWorldUnit > 0.0) {
                isotropicPixelsPerUnit = max(overviewFade.pointWidthCentrePixelsPerWorldUnit
                                                 * overviewFade.pointWidthReferenceDepth / w0
                                                 * max(length(modelMatrix[0].xyz), 1e-9),
                                             1e-4);
            }
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
            if (kTileRoadRibbons) {
                // A road: the rim is the style's edge itself, no feather,
                // and never under half a pixel from the centreline.
                units = max(units, kTileRoadMinimumHalfWidthPx / isotropicPixelsPerUnit);
            } else {
                // The feather at this vertex's scale on screen. Behind the
                // near plane the floored span is far too many pixels a unit
                // and the feather vanishes, which the cut vertex never
                // shows.
                units += kTileDeferredRibbonFeatherPx / isotropicPixelsPerUnit;
            }
            units = min(units, kTileDeferredRibbonMaximumUnits);
            localPosition += normal * units;
        }
    }
    float4 worldPosition = modelMatrix * float4(localPosition, 0.0, 1.0);

    VertexOut out;
    out.position = camera.matrix * worldPosition;
    // The flat surface lies on one plane, so its depth is the projection's
    // z of that plane, scaled by the layer's rank: a scale of 1 minus a
    // place in the rank band, at most 1220 steps, under the real
    // geometry's kFlatRealDepthScale, which the projection already
    // applied and the ground divides out. At a pixel every layer shares
    // the plane's z, so the scales alone order the layers, and the opaque
    // fill layers can draw under a depth write (a pixel is shaded once by
    // its topmost opaque layer) while every real fragment stays nearer.
    // The per-draw offset places the group: ground fills at 0, ground
    // ribbons one class band nearer, the road buckets and the bridge
    // overlay nearer still (GlobeSurfaceDepthRank mirrors the constants).
    // A road's offset is its band (RoadRankDepth), and its style ranks
    // stay inside the band.
    // The rank step is the draw's: a flattened ground's fills
    // (GroundFlattening) overlap nowhere and all take one depth, the
    // band's first step.
    float styleRank = float(vertexIn.styleIndex);
    if (kTileRoadRibbons) {
        styleRank = min(styleRank, kTileRoadBandRanks - 1.0);
    }
    float layerDepthScale = 1.0 - depthBand.offset
        - styleRank * depthBand.rankStep - kFlatTileLayerDepthStep;
    out.position.z *= layerDepthScale / kFlatRealDepthScale;
    out.worldPos = worldPosition.xyz;
    // Nothing cut: the hardware clips at the near plane.
    out.clipDistance[0] = 1.0;
    if (kTileStyleIndexField) {
        out.styleIndex = uint(vertexIn.styleIndex);
        out.lineParameterRaw = float(vertexIn.lineParameter);
    }
    if (kTileCoverageFields) {
        out.lineDistance = float(vertexIn.lineDistance) / 127.0;
        out.deferredEdgePx = deferredEdgePx;
        out.widthAxis = widthAxis;
    }
    if (kTileRoadRibbons) {
        // The road's colour is final here: the style's, with the zoom fade
        // and the width ramp's alpha, all functions of the style and the
        // frame only.
        out.color = half4(styles[vertexIn.styleIndex].color);
        out.color.a *= tileStyleFade(styleZoomFades[vertexIn.styleIndex], overviewFade);
        out.color.a *= half(tilePointWidthRampAlpha(lineStyles[vertexIn.styleIndex], overviewFade.cameraZoom));
        // A road that is invisible this frame is cut whole, so it writes no
        // rank over the roads under it.
        if (out.color.a <= 0.0h) {
            out.clipDistance[0] = -1.0;
        }
    }
    if (kTileFillFields) {
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

/// How much of the sun reaches the ground at a fragment: the flat world
/// pass reads the per-pixel mask, the atlas bake samples the cascades.
static inline float tileGroundShadowFactor(FragmentIn in,
                                           constant Shadow& shadow,
                                           depth2d<float> shadowMap,
                                           texture2d<half> groundShadowMask) {
    if (kGroundShadowMaskEnabled) {
        // One bilinear tap of the mask instead of a cascade lookup in every
        // ground layer. The strength guard mirrors sampleShadowFactor's, so a
        // frame without the mask pass (shadows off, no casters) never samples
        // the 1x1 fallback.
        constexpr sampler maskSampler(coord::pixel, filter::linear, address::clamp_to_edge);
        return shadow.strength > 0.0
            ? float(groundShadowMask.sample(maskSampler, in.position.xy * kGroundShadowMaskScale).r)
            : 1.0;
    }
    // Zero normal: the ground always faces the sun and keeps its tight
    // contact (no normal-offset shift).
    return sampleShadowFactor(shadow, shadowMap, in.worldPos, float3(0.0));
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
    float shadowFactor = tileGroundShadowFactor(in, shadow, shadowMap, groundShadowMask);
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
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    return color;
}

fragment half4 tileFragmentShader(FragmentIn in [[stage_in]],
                                  constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                  constant Shadow& shadow [[buffer(3)]],
                                  constant LineDashUniform& lineDash [[buffer(4)]],
                                  constant Style* styles [[buffer(5), function_constant(kTileLineFields)]],
                                  constant float2* styleZoomFades [[buffer(6), function_constant(kTileLineFields)]],
                                  constant LineStyle* lineStyles [[buffer(7), function_constant(kTileLineFields)]],
                                  depth2d<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
                                  texture2d<half> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]) {
    half4 color = tileFragmentColor(in, overviewFade, shadow, lineDash, styles, styleZoomFades, lineStyles,
                                    shadowMap, groundShadowMask);
    color.rgb = applyGroundFog(color.rgb, in.worldPos, groundFog);
    return color;
}

// The road ribbons (kTileRoadRibbons): the geometry is the road, so there
// is no coverage to compute. Which road owns a pixel is the depth test's
// work, over the rank the vertex stage wrote (RoadRankDepth):
// - An opaque road writes its rank with blending off, so a pixel several
//   roads cover is shaded once, by the road of the highest rank, whatever
//   order they are drawn in.
// - A road that is not opaque this frame (kTileRoadBlended) blends, and
//   writes its rank too, under a test that fails an equal rank: every pixel
//   takes one fragment of a rank, so a translucent road does not darken
//   where two pieces of it overlap. The drawer draws these nearest first,
//   so the pixel belongs to the highest road that covers it. The gaps of a
//   dash pattern are discarded and claim nothing.
// - The edge lines of every road, its rim as one-pixel line primitives
//   over the same rim vertices, draw last through the blended variant at a
//   share of the road's alpha (the draw's alpha scale), tested against the
//   ranks and writing none. A line is one pixel wide and lands on the
//   pixels the body's edge passes through without covering.
//   An equal rank fails the test, so a line shows only on the pixels
//   beside the body, where it softens the steps of the hard edge, and
//   never across the body of its own road or of another road of its
//   style, which is what keeps a junction free of seams.
static inline half4 tileRoadFragmentColor(FragmentIn in,
                                          constant float& alphaScale,
                                          constant Shadow& shadow,
                                          constant LineDashUniform& lineDash,
                                          constant LineStyle* lineStyles,
                                          depth2d<float> shadowMap,
                                          texture2d<half> groundShadowMask) {
    half4 color = in.color;
    float shadowFactor = tileGroundShadowFactor(in, shadow, shadowMap, groundShadowMask);
    if (kTileRoadBlended) {
        color.a *= half(alphaScale);
        // The derivative is taken before the discard: fwidth needs the
        // whole 2x2 quad.
        float parameterSpan = fwidth(in.lineParameterRaw);
        LineStyle lineStyle = lineStyles[in.styleIndex];
        // A vanishing gradient is a saturated parameter (a decoration
        // sharing the style), not an arc: no pattern there.
        if (lineStyle.dashLengthPoints > 0.0 && parameterSpan > 2e-5) {
            // The arc length rides in half tile units (TileVertexIn).
            float unitScale = lineStyle.dashInTileUnits > 0.0 ? 1.0 : lineDash.unitsPerPoint;
            float dashUnits = lineStyle.dashLengthPoints * unitScale;
            float gapUnits = lineStyle.dashGapPoints * unitScale;
            if (dashUnits > 0.0 && gapUnits > 0.0
                && tileDashEdgeDistance(in.lineParameterRaw * 0.5, dashUnits, dashUnits + gapUnits) < 0.0) {
                discard_fragment();
            }
        }
    } else {
        color.a = 1.0h;
    }
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    return color;
}

fragment half4 tileRoadFragmentShader(FragmentIn in [[stage_in]],
                                      constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]],
                                      constant float& alphaScale [[buffer(11), function_constant(kTileRoadBlended)]],
                                      constant Shadow& shadow [[buffer(3)]],
                                      constant LineDashUniform& lineDash [[buffer(4), function_constant(kTileRoadBlended)]],
                                      constant LineStyle* lineStyles [[buffer(7), function_constant(kTileRoadBlended)]],
                                      depth2d<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
                                      texture2d<half> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]) {
    half4 color = tileRoadFragmentColor(in, alphaScale, shadow, lineDash, lineStyles, shadowMap, groundShadowMask);
    color.rgb = applyGroundFog(color.rgb, in.worldPos, groundFog);
    return color;
}
