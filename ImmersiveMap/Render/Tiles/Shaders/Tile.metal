// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

// Ground shadow source. The flat world pass reads the per-pixel ground
// shadow mask (GroundShadowMask.metal), evaluated once per frame for the
// plane every blended ground layer lies on; the globe atlas bake, which never
// has shadows, keeps the direct cascade sampling path and binds a disabled
// uniform. A function constant so each pipeline only declares the texture it
// reads (the other argument is compiled out and needs no binding).
constant bool kGroundShadowMaskEnabled [[function_constant(0)]];
constant bool kSamplesShadowCascades = !kGroundShadowMaskEnabled;

// Add necessary structures for transformation and rendering
struct VertexIn {
    short2 position [[attribute(0)]];
    unsigned char styleIndex [[attribute(1)]];
    char lineDistance [[attribute(2)]];
    short lineParameter [[attribute(3)]];
};

// color and the fade mask are unit-range, so they interpolate as half: fewer
// interpolant registers and double-rate ALU on A-series GPUs (the same split
// the starfield shader uses). Positions stay float.
// The line distances stay float: the antialiasing band can be a small
// fraction of the normalized field on wide lines, below half's precision
// near 1.0, and the arc parameter spans thousands of tile units.
// lineStyle packs the per-style constants (edge threshold, width points,
// dash points, gap points); constant per primitive, so half is exact enough.
struct VertexOut {
    float4 position [[position]];
    // Signed distances to the four edges of the placeIn slot, in the source
    // tile's local units (see localClipBounds): the rasterizer clips the
    // primitive where any goes negative, so a retained substitute never
    // overlaps the neighboring exact tiles, and the fragment stage never
    // needs a discard (which would defeat hidden surface removal for every
    // ground draw). Exact placements get a disabled clip: all four stay
    // positive.
    float clipDistance [[clip_distance]] [4];
    float3 worldPos;
    half4 color;
    half lowZoomFadeMask;
    float lineDistance;
    float lineParameter;
    half4 lineStyle;
    half lineMinimumWidthPoints;
    half lineMaximumWidthPoints;
    // 1 when the dash pattern is already in tile units (world-locked paint),
    // 0 when it is in points and scales by the draw's unitsPerPoint.
    half lineDashInTileUnits;
};

// The fragment stage's view of VertexOut: the same interpolants matched by
// name, without the clip distances (consumed by the rasterizer; MSL does not
// allow them in a stage_in struct).
struct FragmentIn {
    float4 position [[position]];
    float3 worldPos;
    half4 color;
    half lowZoomFadeMask;
    float lineDistance;
    float lineParameter;
    half4 lineStyle;
    half lineMinimumWidthPoints;
    half lineMaximumWidthPoints;
    half lineDashInTileUnits;
};

struct Style {
    float4 color;
    /// Street-palette counterpart of color; the vertex stage lerps between
    /// the two with the per-frame street blend, so the ground palette hands
    /// over continuously in camera zoom instead of stepping per tile zoom.
    float4 streetColor;
};

/// Per-frame overview-to-street palette blend, from camera zoom.
struct StreetPaletteUniform {
    float blend;
};

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
    // Ceiling for a world-locked width in points (zero: none); see the
    // Swift TileLineStyle.maximumWidthPoints.
    float maximumWidthPoints;
    float reserved2;
};

struct OverviewFadeUniform {
    float overviewAlpha;
    float roadAlpha;
    float landuseAlpha;
    float pixelsPerPoint;
    // 0: roads are symbols (point ceiling holds); 1: true surfaces. Morphs
    // continuously with the camera, see LowZoomOverviewFade.roadSurfaceBlend.
    float roadSurfaceBlend;
    // How far road markings have come in, over their own camera-zoom band
    // above the width morph: paint is a length on the ground and only
    // resolves as paint once a three-metre dash is more than a point or two
    // across. See LowZoomOverviewFade.roadMarkingAlpha.
    float roadMarkingAlpha;
    // The live camera zoom, for the per-class fade: a mask of 10 or more
    // carries the zoom a road class fades in from (see
    // LowZoomOverviewFade.classFadeMask), and the class comes in over the
    // following zoom level, continuous with the camera.
    float cameraZoom;
};

/// Per-draw dash scale: tile units per layout point at the tile's nominal
/// display scale. A constant of the tile and the viewport, never of the live
/// camera, so the dash pattern stays anchored to the geometry instead of
/// crawling under camera motion (see LineDashNominalScale).
struct LineDashUniform {
    float unitsPerPoint;
};

vertex VertexOut tileVertexShader(VertexIn vertexIn [[stage_in]],
                                  constant Camera& camera [[buffer(1)]],
                                  constant Style* styles [[buffer(2)]],
                                  constant float4x4& modelMatrix [[buffer(3)]],
                                  constant float* lowZoomFadeMasks [[buffer(4)]],
                                  constant LineStyle* lineStyles [[buffer(5)]],
                                  constant StreetPaletteUniform& streetPalette [[buffer(6)]],
                                  constant float4& localClipBounds [[buffer(7)]]) {
    
    Style style = styles[vertexIn.styleIndex];
    float4x4 matrix = camera.matrix;
    
    float4 worldPosition = modelMatrix * float4(float2(vertexIn.position.xy), 0.0, 1.0);
    float4 clipPosition = matrix * worldPosition;
    
    VertexOut out;
    out.position = clipPosition;
    // localClipBounds: (minX, minY, maxX, maxY) of the placeIn slot in the
    // source tile's local coordinates; positive inside.
    float2 localPosition = float2(vertexIn.position.xy);
    out.clipDistance[0] = localPosition.x - localClipBounds.x;
    out.clipDistance[1] = localClipBounds.z - localPosition.x;
    out.clipDistance[2] = localPosition.y - localClipBounds.y;
    out.clipDistance[3] = localClipBounds.w - localPosition.y;
    out.worldPos = worldPosition.xyz;
    out.color = half4(mix(style.color, style.streetColor, streetPalette.blend));
    out.lowZoomFadeMask = half(lowZoomFadeMasks[vertexIn.styleIndex]);
    LineStyle lineStyle = lineStyles[vertexIn.styleIndex];
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
    out.lineMaximumWidthPoints = half(lineStyle.maximumWidthPoints);
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
static inline half tileLineCoverage(float lineDistance,
                                    float lineParameter,
                                    half4 lineStyle,
                                    half minimumWidthPoints,
                                    half maximumWidthPoints,
                                    half dashInTileUnits,
                                    float pixelsPerPoint,
                                    float roadSurfaceBlend,
                                    float dashUnitsPerPoint) {
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
    if (widthPoints > 0.0h) {
        edgePx = min(float(widthPoints) * 0.5 * pixelsPerPoint, rimPx - 0.5);
    } else {
        // World-locked width, optionally floored: a road class never thins
        // into an unreadable hairline at region zooms, yet keeps its natural
        // world growth once wider than the floor.
        edgePx = float(edgeThreshold) * rimPx;
        // The ceiling first: at region zooms the world width is far wider on
        // screen than a readable road symbol, and the road draws at the
        // symbol until the world catches down to it, continuously with the
        // camera (the ribbon is tessellated at the world width, so the
        // ceiling only ever pulls the edge inward; it never clamps to the
        // rim the way the floor has to).
        if (maximumWidthPoints > 0.0h) {
            // Symbol to surface: at region zooms the road draws at its
            // symbol width (the ceiling), and morphs into its true width as
            // the camera descends, so the width never steps at a tile level.
            float symbolPx = min(edgePx, float(maximumWidthPoints) * 0.5 * pixelsPerPoint);
            edgePx = mix(symbolPx, edgePx, roadSurfaceBlend);
        }
        if (minimumWidthPoints > 0.0h) {
            float floorPx = min(float(minimumWidthPoints) * 0.5 * pixelsPerPoint, rimPx - 0.5);
            edgePx = max(edgePx, floorPx);
        }
    }
    float sideDistancePx = edgePx - abs(lineDistance) * rimPx;
    float coverage = smoothstep(-0.5, 0.5, sideDistancePx);

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
            // the period (the route renderer's construction), so both edges
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

// The placeIn clip of a retained substitute is applied by the rasterizer
// through the vertex stage's clip distances, so nothing here discards: every
// fragment that reaches this function is inside its slot, and the GPU can
// resolve visibility (and drop what later opaque geometry covers) before
// shading.
fragment half4 tileFragmentShader(FragmentIn in [[stage_in]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                  constant HorizonFog& horizonFog [[buffer(2)]],
                                  constant Shadow& shadow [[buffer(3)]],
                                  constant LineDashUniform& lineDash [[buffer(4)]],
                                  depth2d_array<float> shadowMap [[texture(0), function_constant(kSamplesShadowCascades)]],
                                  texture2d<half, access::read> groundShadowMask [[texture(1), function_constant(kGroundShadowMaskEnabled)]]) {
    float shadowFactor;
    if (kGroundShadowMaskEnabled) {
        // One read of the per-pixel mask instead of a cascade lookup in every
        // ground layer; the strength guard mirrors sampleShadowFactor's, so a
        // frame without the mask pass (shadows off, no casters) never reads
        // the 1x1 fallback out of bounds.
        shadowFactor = shadow.strength > 0.0
            ? float(groundShadowMask.read(uint2(in.position.xy)).r)
            : 1.0;
    } else {
        shadowFactor = sampleShadowFactor(shadow, shadowMap, in.worldPos, float3(0.0));
    }
    half lineCoverage = tileLineCoverage(in.lineDistance,
                                         in.lineParameter,
                                         in.lineStyle,
                                         in.lineMinimumWidthPoints,
                                         in.lineMaximumWidthPoints,
                                         in.lineDashInTileUnits,
                                         overviewFade.pixelsPerPoint,
                                         overviewFade.roadSurfaceBlend,
                                         lineDash.unitsPerPoint);
    half4 color = in.color;
    half fade = 1.0h;
    if (in.lowZoomFadeMask >= 9.5h) {
        float startZoom = float(in.lowZoomFadeMask) - 10.0;
        float t = clamp(overviewFade.cameraZoom - startZoom, 0.0, 1.0);
        fade = half(t * t * (3.0 - 2.0 * t));
    } else if (in.lowZoomFadeMask >= 3.5h) {
        fade = half(overviewFade.roadMarkingAlpha);
    } else if (in.lowZoomFadeMask >= 2.5h) {
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
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    color.rgb = applyHorizonFog(color.rgb, horizonFog, in.worldPos);
    return color;
}
