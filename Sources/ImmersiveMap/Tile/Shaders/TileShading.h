// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileShading.h
//  ImmersiveMap
//
//  Everything the flat tile shader (Tile.metal) and the sphere tile shader
//  (TileSphere.metal) share: the vertex format, the per-style uniforms, the
//  analytic line coverage, and the two stages' common bodies (the style
//  resolution in the vertex stage, the coverage and fade in the fragment
//  stage). One copy, so the two surfaces cannot drift apart in how a style
//  is drawn; only the projection and the lighting differ per surface.
//

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"

#ifndef TILE_SHADING
#define TILE_SHADING

// Add necessary structures for transformation and rendering
struct VertexIn {
    short2 position [[attribute(0)]];
    unsigned char styleIndex [[attribute(1)]];
    char lineDistance [[attribute(2)]];
    short lineParameter [[attribute(3)]];
    // A deferred ribbon's extrusion direction (snorm, unit; zero on a
    // centreline hub and on every pre-extruded vertex): the flat vertex
    // stage moves the vertex along it by the style's width on screen.
    float2 normal [[attribute(4)]];
};


struct Style {
    float4 color;
    /// The footprint fade target; alpha is the fade strength (0: the style
    /// never fades). Mirror of TilePolygonStyle.
    float4 farColor;
};

/// Per-draw footprint fade parameters (Tile.metal, fragment buffer 10):
/// the source tile's units per world unit, and the footprint band in tile
/// units per pixel over which a fill fades to its far colour. Mirror of
/// TileFootprintFadeUniform.
struct FootprintFadeUniform {
    float unitsPerWorld;
    float startUnits;
    float endUnits;
    float _padding;
};

/// How far a fill has faded to its far colour at a pixel: the pixel's
/// ground footprint along its longer screen axis, in the source tile's
/// units, against the fade band. Takes screen-space derivatives, so it must
/// run in uniform control flow. Mirrored by GroundFootprintFade.amount.
static inline float tileFootprintFadeAmount(float3 worldPos, constant FootprintFadeUniform& fade) {
    float2 dx = dfdx(worldPos.xy);
    float2 dy = dfdy(worldPos.xy);
    float unitsPerPixel = max(length(dx), length(dy)) * fade.unitsPerWorld;
    return smoothstep(fade.startUnits, fade.endUnits, unitsPerPixel);
}

/// Mirror of the Swift `TileLineStyle`; indexed per style alongside `Style`.
struct LineStyle {
    float widthPoints;
    float dashLengthPoints;
    float dashGapPoints;
    float edgeThreshold;
    float minimumWidthPoints;
    // Non-zero: dashLengthPoints/dashGapPoints are tile units and the
    // pattern is cut from arc length without the point-to-unit conversion
    // (world-locked paint such as a lane divider).
    float dashInTileUnits;
    // The styled half-width in tile units, for the deferred extrusion.
    float halfWidthUnits;
    // The camera zoom a point-locked width is frozen on the ground from
    // (zero: never); see the Swift TileLineStyle.worldLockZoom.
    float worldLockZoom;
    // The zoom ramp of a point-locked width: `rampStartWidthPoints` wide and
    // at `rampStartAlpha` of the colour's alpha up to `rampStartZoom`, the
    // style's own width and alpha from `rampEndZoom`, continuous in camera
    // zoom between. An end zoom of zero: no ramp. See the Swift
    // TileLineStyle.
    float rampStartWidthPoints;
    float rampStartZoom;
    float rampEndZoom;
    float rampStartAlpha;
};

/// How far a style's zoom ramp has come, 0...1; one for a style without.
static inline float tilePointWidthRampProgress(LineStyle lineStyle, float cameraZoom) {
    if (lineStyle.rampEndZoom <= lineStyle.rampStartZoom) {
        return 1.0;
    }
    return clamp((cameraZoom - lineStyle.rampStartZoom) / (lineStyle.rampEndZoom - lineStyle.rampStartZoom),
                 0.0, 1.0);
}

/// The point-locked width of a style at a camera zoom: the ramp runs in
/// ratios, the same growth per zoom level all the way, so nothing about
/// the width steps when the engine swaps the tile level serving the line.
static inline float tilePointWidthPoints(LineStyle lineStyle, float cameraZoom) {
    float progress = tilePointWidthRampProgress(lineStyle, cameraZoom);
    if (progress >= 1.0 || lineStyle.rampStartWidthPoints <= 0.0) {
        return lineStyle.widthPoints;
    }
    return lineStyle.rampStartWidthPoints
        * pow(lineStyle.widthPoints / lineStyle.rampStartWidthPoints, progress);
}

/// The share of the colour's alpha the ramp leaves at a camera zoom.
static inline float tilePointWidthRampAlpha(LineStyle lineStyle, float cameraZoom) {
    return mix(lineStyle.rampStartAlpha, 1.0, tilePointWidthRampProgress(lineStyle, cameraZoom));
}

/// How much wider than its points a point-locked width draws: one up to
/// the style's world lock zoom, doubling with every zoom level past it,
/// which is the width staying put on the ground while the camera descends.
/// Continuous in camera zoom. One for a style without a lock.
static inline float tilePointWidthWorldScale(float worldLockZoom, float cameraZoom) {
    if (worldLockZoom <= 0.0) {
        return 1.0;
    }
    return exp2(max(cameraZoom - worldLockZoom, 0.0));
}

/// The visible half-width of a line on screen, in pixels, from its style
/// and the pixels one tile unit spans where it is drawn: the point-locked
/// width as is, the world-locked width over its floor (the same resolution
/// `tileLineCoverage` reaches through the distance field). The deferred
/// ribbons' vertex stage extrudes to this plus one pixel of feather.
static inline float tileLineEdgePixels(LineStyle lineStyle,
                                       float pixelsPerUnit,
                                       float pixelsPerPoint,
                                       float cameraZoom) {
    if (lineStyle.widthPoints > 0.0) {
        return tilePointWidthPoints(lineStyle, cameraZoom) * 0.5 * pixelsPerPoint
            * tilePointWidthWorldScale(lineStyle.worldLockZoom, cameraZoom);
    }
    float edgePx = lineStyle.halfWidthUnits * pixelsPerUnit;
    if (lineStyle.minimumWidthPoints > 0.0) {
        edgePx = max(edgePx, lineStyle.minimumWidthPoints * 0.5 * pixelsPerPoint);
    }
    return edgePx;
}

/// The feather a deferred ribbon is extruded past its visible edge: the
/// one-pixel antialiasing ramp of `tileLineCoverage`.
constant float kTileDeferredRibbonFeatherPx = 1.0;

struct OverviewFadeUniform {
    float overviewAlpha;
    float roadAlpha;
    float landuseAlpha;
    float pixelsPerPoint;
    // How far road markings have come in, over their own camera-zoom band:
    // paint is a length on the ground and only resolves as paint once a
    // three-metre dash is more than a point or two across. See
    // LowZoomOverviewFade.roadMarkingAlpha.
    float roadMarkingAlpha;
    // The live camera zoom, for the per-class fade: a mask of 10 or more
    // carries the zoom a road class fades in from (see
    // LowZoomOverviewFade.classFadeMask), and the class comes in over the
    // following zoom level, continuous with the camera.
    float cameraZoom;
    // The drawable in pixels: what the deferred ribbons' vertex stage
    // converts a tile unit's clip-space span into pixels with.
    float2 viewportSizePx;
    // The view depth of the ground point at the centre of the screen: what
    // a point-locked deferred ribbon's width is stated at. Zero: the width
    // holds in pixels at every depth. See tilePointWidthPerspectiveScale.
    float pointWidthReferenceDepth;
    // The roads' thinness fade, as a width on screen in pixels; see
    // tileRoadThinnessFade. A zero opaque width turns it off.
    float roadFadeOpaqueWidthPx;
    // The footprint fade of the building fills, as footprint areas on
    // screen in square pixels (BuildingFootprintFade). A zero opaque area
    // turns it off. The extruded buildings do not fade.
    float footprintGoneAreaPx;
    float footprintOpaqueAreaPx;
    // The pixels one world unit of ground spans across the view at the
    // centre of the screen: what turns a width in pixels there into the
    // width on the ground every road of that style lies at. Zero: the
    // widths follow the distance alone.
    float pointWidthCentrePixelsPerWorldUnit;
    // The camera matrix's columns of the two ground axes, their x, y and w
    // rows: what a ground direction becomes in clip space, for the fragment
    // stage, which has no camera matrix of its own.
    packed_float3 groundAxisXClip;
    packed_float3 groundAxisYClip;
};

/// The alpha of a fill of the footprint fade band (mask 5, see
/// LowZoomOverviewFade.footprintFadeMask) from its polygon's footprint on
/// screen: the radius the parser packed into the normal bytes (two
/// base-128 digits of quarter tile units), through the model's scale into
/// world units, times the pixels a world unit spans at the vertex's view
/// depth, as the area of the square inscribed in that disc. Gone at the
/// gone area and under, whole at the opaque area and over. Mirrored by
/// BuildingFootprintFade.swift.
static inline float tileFootprintAlpha(float2 packedRadius,
                                       float4x4 modelMatrix,
                                       float4x4 cameraMatrix,
                                       float viewDepth,
                                       constant OverviewFadeUniform& overviewFade) {
    if (overviewFade.footprintOpaqueAreaPx <= 0.0) {
        return 1.0;
    }
    float quarterUnits = round(packedRadius.x * 127.0) * 128.0 + round(packedRadius.y * 127.0);
    if (quarterUnits <= 0.0) {
        return 1.0;
    }
    float radiusWorld = quarterUnits * 0.25 * length(modelMatrix[0].xyz);
    // The projection's vertical focal length is the length of the camera
    // matrix's y row (the view part is a rotation), on the perspective
    // camera and on the rasterizer's straight-down one alike.
    float focal = length(float3(cameraMatrix[0][1], cameraMatrix[1][1], cameraMatrix[2][1]));
    float radiusPx = radiusWorld * overviewFade.viewportSizePx.y * 0.5 * focal / max(viewDepth, 1e-6);
    float areaPx = 2.0 * radiusPx * radiusPx;
    return smoothstep(overviewFade.footprintGoneAreaPx,
                      max(overviewFade.footprintOpaqueAreaPx, overviewFade.footprintGoneAreaPx + 1e-3),
                      areaPx);
}

/// The pixels one world unit of ground spans on screen along `axis` at a
/// point of the screen: across the view the ground shrinks with the
/// distance and nothing else, into the view the grazing angle flattens it
/// much faster, down to nothing at the horizon. `ndc` is the point on
/// screen, `viewDepth` its depth.
static inline float tileGroundPixelsPerWorldUnit(float2 axis,
                                                 float2 ndc,
                                                 float viewDepth,
                                                 constant OverviewFadeUniform& overviewFade) {
    float3 clipStep = float3(overviewFade.groundAxisXClip) * axis.x
        + float3(overviewFade.groundAxisYClip) * axis.y;
    float2 halfViewport = overviewFade.viewportSizePx * 0.5;
    return length((clipStep.xy - ndc * clipStep.z) * halfViewport) / max(viewDepth, 1e-6);
}

/// How much a point-locked deferred ribbon's width scales at a point of the
/// screen. The width lies on the ground: one ground width per road,
/// whatever way the road runs, chosen so that a road running along the
/// view through the centre of the screen is exactly its style's points
/// wide. From there the perspective does the rest, as it does to the
/// blocks around the road: thinner toward the horizon, wider in the
/// foreground, and a road across the view thinner than one along it under
/// a tilted camera. Nothing about it depends on the camera's bearing, so
/// a turn of the camera changes no road's width on the ground and every
/// segment of a bend is as wide as the next. `axis` is the ground
/// direction the width is laid in. A zero axis (the hub of a fan, the
/// centreline of a segment) takes the distance alone.
static inline float tilePointWidthPerspectiveScale(constant OverviewFadeUniform& overviewFade,
                                                   float viewDepth,
                                                   float2 axis,
                                                   float2 ndc) {
    if (overviewFade.pointWidthReferenceDepth <= 0.0) {
        return 1.0;
    }
    if (overviewFade.pointWidthCentrePixelsPerWorldUnit <= 0.0 || dot(axis, axis) <= 1e-6) {
        return overviewFade.pointWidthReferenceDepth / max(viewDepth, 1e-6);
    }
    return tileGroundPixelsPerWorldUnit(normalize(axis), ndc, viewDepth, overviewFade)
        / overviewFade.pointWidthCentrePixelsPerWorldUnit;
}

/// The narrowest antialiasing band a line is laid in: half a pixel each
/// side of its centre. A thinner line draws in it at the share of it the
/// line covers (tileLineCoverage).
constant float kTileLineMinimumEdgePx = 0.5;

/// How much of a road is left at its width on screen: a road thinner than
/// `opaqueWidthPx` fades with its width, down to nothing at no width, so a
/// road the perspective has thinned leaves the picture instead of staying
/// a full-strength hairline. One when `opaqueWidthPx` is zero (off).
/// Mirrored by RoadThinnessFade.alpha.
static inline float tileRoadThinnessFade(float widthPx, float opaqueWidthPx) {
    if (opaqueWidthPx <= 0.0) {
        return 1.0;
    }
    return smoothstep(0.0, opaqueWidthPx, widthPx);
}

/// Per-draw dash scale: tile units per layout point at the tile's nominal
/// display scale. A constant of the tile and the viewport, never of the live
/// camera, so the dash pattern stays anchored to the geometry instead of
/// crawling under camera motion (see LineDashNominalScale).
struct LineDashUniform {
    float unitsPerPoint;
};

/// The per-vertex style outputs both tile vertex stages carry to their
/// fragment stage; see the interpolant notes on `VertexOut` in Tile.metal.
struct TileVertexStyle {
    half4 color;
    half lowZoomFadeMask;
    float lineDistance;
    float lineParameter;
    half4 lineStyle;
    half lineMinimumWidthPoints;
    half lineDashInTileUnits;
};

/// Resolves a vertex's style: the colour, the fade mask, and the line
/// field unpacked the way the fragment coverage reads it.
static inline TileVertexStyle tileVertexStyle(VertexIn vertexIn,
                                              constant Style* styles,
                                              constant float* lowZoomFadeMasks,
                                              constant LineStyle* lineStyles) {
    Style style = styles[vertexIn.styleIndex];
    LineStyle lineStyle = lineStyles[vertexIn.styleIndex];
    TileVertexStyle out;
    out.color = half4(style.color);
    out.lowZoomFadeMask = half(lowZoomFadeMasks[vertexIn.styleIndex]);
    out.lineDistance = float(vertexIn.lineDistance) / 127.0;
    // The longitudinal parameter is style-interpreted (see TileVertexIn): a
    // point-dashed style stores arc length in half tile units, a solid one
    // the normalized end-feather distance.
    out.lineParameter = lineStyle.dashLengthPoints > 0.0
        ? float(vertexIn.lineParameter) * 0.5
        : float(vertexIn.lineParameter) / 32767.0;
    out.lineStyle = half4(lineStyle.edgeThreshold,
                          lineStyle.widthPoints,
                          lineStyle.dashLengthPoints,
                          lineStyle.dashGapPoints);
    out.lineMinimumWidthPoints = half(lineStyle.minimumWidthPoints);
    out.lineDashInTileUnits = lineStyle.dashInTileUnits > 0.0 ? 1.0h : 0.0h;
    return out;
}

/// Analytic coverage of line geometry: the tessellator extrudes lines wider
/// than their styled width and stores a signed distance field in the vertices
/// (see `TileVertexIn`), so the visible edge is an isoline of the
/// interpolated field, feathered over one screen pixel. The longitudinal
/// field does the same for free butt ends (dash cuts, line ends): its zero
/// isoline is the styled cut, and it sits saturated at 1 everywhere the end
/// must stay hard (interior vertices, tile-seam and road-junction
/// continuations). This is the only edge antialiasing lines get on the globe,
/// whose atlas pages render without MSAA. Must be called before any divergent
/// discard: fwidth evaluates screen-space derivatives.
///
/// Where the visible edge sits comes in two flavors. A world-locked style
/// (widthPoints == 0) puts it on the edge-threshold isoline: the width the
/// tessellator baked, scaling with the tile on screen. A point-locked style
/// resolves the edge in raster units instead: the field's per-pixel gradient
/// converts the requested half-width into an isoline each frame, so the line
/// holds its designed width through fractional zoom instead of pumping with
/// the tile scale, and the baked (extruded) geometry only bounds how wide it
/// can get. The half-pixel inset keeps the edge feathered even when the
/// request exceeds the geometry; past the rim the clamp goes negative and
/// the line fades out instead of aliasing.
///
/// The longitudinal parameter is style-interpreted. A point-dashed style
/// carries arc length in tile units, and the dash pattern is cut here, per
/// fragment, on the fixed unit grid `dashUnitsPerPoint` scales (anchored to
/// the geometry, so the pattern holds still under camera motion), while the
/// parameter's screen-space derivative supplies only the antialiasing band,
/// giving the cuts the same one-pixel ramp as the sides. A solid style
/// carries the end-feather distance whose zero isoline is a free butt end's
/// styled cut.
/// - Parameter deferredEdgePx: a deferred ribbon's visible half-width in
///   pixels, resolved by its vertex stage, which extruded the rim one
///   feather past it (Tile.metal); zero for a pre-extruded ribbon, whose
///   edge is read off the baked field below.
static inline half tileLineCoverage(float lineDistance,
                                    float lineParameter,
                                    half4 lineStyle,
                                    half minimumWidthPoints,
                                    half dashInTileUnits,
                                    float pixelsPerPoint,
                                    float dashUnitsPerPoint,
                                    float deferredEdgePx) {
    // The derivatives are taken before the threshold test: fwidth needs the
    // whole 2x2 quad, so it must not sit behind potentially divergent flow.
    float sideSpan = max(fwidth(lineDistance), 1e-5);
    float parameterSpan = fwidth(lineParameter);
    half edgeThreshold = lineStyle.x;
    if (edgeThreshold <= 0.0h) {
        return 1.0h;
    }
    float rimPx = 1.0 / sideSpan;
    half widthPoints = lineStyle.y;
    float edgePx;
    if (deferredEdgePx > 0.0) {
        // The vertex stage resolved the width and put the rim one feather
        // past it: the edge is where it said, bounded by the rim like any.
        edgePx = min(deferredEdgePx, rimPx - 0.5);
    } else if (widthPoints > 0.0h) {
        edgePx = min(float(widthPoints) * 0.5 * pixelsPerPoint, rimPx - 0.5);
    } else {
        // World-locked width, optionally floored: a road class never thins
        // into an unreadable hairline at region zooms, yet keeps its natural
        // world growth once wider than the floor.
        edgePx = float(edgeThreshold) * rimPx;
        if (minimumWidthPoints > 0.0h) {
            float floorPx = min(float(minimumWidthPoints) * 0.5 * pixelsPerPoint, rimPx - 0.5);
            edgePx = max(edgePx, floorPx);
        }
    }
    // A line under a pixel wide covers a fraction of the pixels it crosses,
    // and draws as that: the antialiasing band is a pixel wide whatever the
    // line is, so the band is laid a pixel wide and carries the share of
    // it the line covers (Mapbox GL's rule). The line is not made a pixel
    // wide: it keeps the light a line of its width has, and fades out as
    // it thins instead of standing as a solid hairline. Without the share a
    // line of no width at all would still draw at half strength, and one
    // laid at its own width would flicker as its sub-pixel band crossed
    // pixel centres. The rim still bounds the edge: the ribbon is
    // tessellated wide enough for this (ParseLine.minimumExtrudedHalfWidth).
    float requestedEdgePx = edgePx;
    edgePx = max(edgePx, min(kTileLineMinimumEdgePx, rimPx - 0.5));
    float widthShare = clamp(requestedEdgePx / kTileLineMinimumEdgePx, 0.0, 1.0);
    float sideDistancePx = edgePx - abs(lineDistance) * rimPx;
    float coverage = smoothstep(-0.5, 0.5, sideDistancePx) * widthShare;

    half dashLengthPoints = lineStyle.z;
    if (dashLengthPoints > 0.0h) {
        // A vanishing gradient means the parameter is saturated (polygon
        // decoration sharing the style) rather than a real arc: skip the
        // pattern instead of smearing a constant.
        float unitsPerPixel = parameterSpan;
        // A world-locked pattern is already in tile units: paint on the
        // ground keeps its metre period whatever the camera or the serving
        // tile level does. A point-locked one converts at the draw's nominal
        // scale.
        float unitScale = dashInTileUnits > 0.5h ? 1.0 : dashUnitsPerPoint;
        float dashUnits = float(dashLengthPoints) * unitScale;
        float gapUnits = float(lineStyle.w) * unitScale;
        float period = dashUnits + gapUnits;
        if (unitsPerPixel > 1e-5 && dashUnits > 0.0 && gapUnits > 0.0) {
            // Signed distance to the nearest dash boundary, wrapped around
            // the period, so both edges
            // of every dash carry the full antialiasing band.
            float phase = fmod(lineParameter, period);
            if (phase < 0.0) {
                phase += period;
            }
            float centered = phase - dashUnits * 0.5;
            centered -= period * round(centered / period);
            float distanceToEdgeUnits = dashUnits * 0.5 - abs(centered);
            coverage *= smoothstep(-0.5, 0.5, distanceToEdgeUnits / unitsPerPixel);
        }
    } else {
        float endDistancePx = lineParameter / max(parameterSpan, 1e-5);
        coverage *= smoothstep(-0.5, 0.5, endDistancePx);
    }
    return half(coverage);
}

/// The zoom fade of a style from its baked mask: a class fade (mask of 10 or
/// more carries the zoom the class fades in from) evaluates against the live
/// camera zoom, the fixed bands take the frame's alphas, and zero means no
/// fade.
static inline half tileStyleFade(half lowZoomFadeMask, constant OverviewFadeUniform& overviewFade) {
    if (lowZoomFadeMask >= 9.5h) {
        float startZoom = float(lowZoomFadeMask) - 10.0;
        float t = clamp(overviewFade.cameraZoom - startZoom, 0.0, 1.0);
        return half(t * t * (3.0 - 2.0 * t));
    } else if (lowZoomFadeMask >= 4.5h) {
        // The footprint fade band: no zoom fade, the flat vertex stage
        // resolves the alpha per polygon (tileFootprintAlpha).
        return 1.0h;
    } else if (lowZoomFadeMask >= 3.5h) {
        return half(overviewFade.roadMarkingAlpha);
    } else if (lowZoomFadeMask >= 2.5h) {
        return half(overviewFade.landuseAlpha);
    } else if (lowZoomFadeMask >= 1.5h) {
        return half(overviewFade.roadAlpha);
    } else if (lowZoomFadeMask >= 0.5h) {
        return half(overviewFade.overviewAlpha);
    }
    return 1.0h;
}

/// The analytic coverage of a lines-class fragment from the flat style
/// index, apart from the colour: what the road sheet's depth stage reads to
/// tell a ribbon's body from its antialiasing fringe (Tile.metal).
static inline half tileLineFragmentCoverage(uint styleIndex,
                                            float lineDistance,
                                            float lineParameterRaw,
                                            constant LineStyle* lineStyles,
                                            constant OverviewFadeUniform& overviewFade,
                                            constant LineDashUniform& lineDash,
                                            float deferredEdgePx) {
    LineStyle lineStyle = lineStyles[styleIndex];
    // Same decode as tileVertexStyle: arc length in half tile units for a
    // dashed style, the normalized end-feather distance otherwise.
    float lineParameter = lineStyle.dashLengthPoints > 0.0
        ? lineParameterRaw * 0.5
        : lineParameterRaw / 32767.0;
    // The point width at this camera zoom (a pre-extruded ribbon resolves
    // its edge from it right here, a deferred one did in its vertex stage).
    float widthPoints = lineStyle.widthPoints > 0.0
        ? tilePointWidthPoints(lineStyle, overviewFade.cameraZoom)
        : 0.0;
    half4 packedLineStyle = half4(lineStyle.edgeThreshold,
                                  widthPoints,
                                  lineStyle.dashLengthPoints,
                                  lineStyle.dashGapPoints);
    return tileLineCoverage(lineDistance,
                            lineParameter,
                            packedLineStyle,
                            half(lineStyle.minimumWidthPoints),
                            lineStyle.dashInTileUnits > 0.0 ? 1.0h : 0.0h,
                            overviewFade.pixelsPerPoint,
                            lineDash.unitsPerPoint,
                            deferredEdgePx);
}

/// The lines-class fragment resolves its whole style from the flat style
/// index: the palette-blended colour with the zoom fade, times the analytic
/// line coverage. The vertex stage exports only the index and the two truly
/// per-vertex line fields (raw, undecoded), which cuts a ribbon vertex's
/// interpolants to a third; every constant read here is uniform across the
/// primitive, so the loads hit cache. The longitudinal parameter arrives
/// raw because its decode scale is a style constant: scaling after
/// interpolation is exact, and its screen derivative stays linear.
static inline half4 tileLineFragmentColor(uint styleIndex,
                                          float lineDistance,
                                          float lineParameterRaw,
                                          constant Style* styles,
                                          constant float* lowZoomFadeMasks,
                                          constant LineStyle* lineStyles,
                                          constant OverviewFadeUniform& overviewFade,
                                          constant LineDashUniform& lineDash,
                                          float deferredEdgePx) {
    Style style = styles[styleIndex];
    half4 color = half4(style.color);
    color.a *= tileStyleFade(half(lowZoomFadeMasks[styleIndex]), overviewFade);
    color.a *= half(tilePointWidthRampAlpha(lineStyles[styleIndex], overviewFade.cameraZoom));
    color.a *= tileLineFragmentCoverage(styleIndex, lineDistance, lineParameterRaw,
                                        lineStyles, overviewFade, lineDash, deferredEdgePx);
    return color;
}

/// The ground colour of a fragment before lighting: the style colour with
/// its alpha scaled by the analytic line coverage. The zoom fade is already
/// folded into the colour's alpha by the vertex stage (a function of the
/// style and the frame only), on the plane and on the sphere alike. Takes
/// screen-space derivatives (inside `tileLineCoverage`), so it must run in
/// uniform control flow.
static inline half4 tileGroundColor(TileVertexStyle style,
                                    constant OverviewFadeUniform& overviewFade,
                                    constant LineDashUniform& lineDash) {
    half lineCoverage = tileLineCoverage(style.lineDistance,
                                         style.lineParameter,
                                         style.lineStyle,
                                         style.lineMinimumWidthPoints,
                                         style.lineDashInTileUnits,
                                         overviewFade.pixelsPerPoint,
                                         lineDash.unitsPerPoint,
                                         0.0);
    half4 color = style.color;
    color.a *= lineCoverage;
    return color;
}

#endif
