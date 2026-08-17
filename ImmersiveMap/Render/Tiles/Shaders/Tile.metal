// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

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
    float2 localPosition;
    float3 worldPos;
    half4 color;
    half lowZoomFadeMask;
    float lineDistance;
    float lineParameter;
    half4 lineStyle;
    half lineMinimumWidthPoints;
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
    float reserved0;
    float reserved1;
    float reserved2;
};

struct OverviewFadeUniform {
    float overviewAlpha;
    float roadAlpha;
    float landuseAlpha;
    float pixelsPerPoint;
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
                                  constant StreetPaletteUniform& streetPalette [[buffer(6)]]) {
    
    Style style = styles[vertexIn.styleIndex];
    float4x4 matrix = camera.matrix;
    
    float4 worldPosition = modelMatrix * float4(float2(vertexIn.position.xy), 0.0, 1.0);
    float4 clipPosition = matrix * worldPosition;
    
    VertexOut out;
    out.position = clipPosition;
    out.localPosition = float2(vertexIn.position.xy);
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
                                    float pixelsPerPoint,
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
        float dashUnits = float(dashLengthPoints) * dashUnitsPerPoint;
        float gapUnits = float(lineStyle.w) * dashUnitsPerPoint;
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

// localClipBounds: (minX, minY, maxX, maxY) in the source tile's local coordinates.
// A retained substitute is drawn as the full source quad - fragments outside the
// placeIn slot are discarded so they don't overlap neighboring exact tiles.
fragment half4 tileFragmentShader(VertexOut in [[stage_in]],
                                  constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                  constant float4& localClipBounds [[buffer(1)]],
                                  constant HorizonFog& horizonFog [[buffer(2)]],
                                  constant Shadow& shadow [[buffer(3)]],
                                  constant LineDashUniform& lineDash [[buffer(4)]],
                                  depth2d_array<float> shadowMap [[texture(0)]]) {
    // The shadow factor and the line coverage come first: both evaluate
    // screen-space derivatives, which are undefined in any 2x2 quad after a
    // divergent discard (MSL spec), so the clip discard must not precede them.
    float shadowFactor = sampleShadowFactor(shadow, shadowMap, in.worldPos, float3(0.0));
    half lineCoverage = tileLineCoverage(in.lineDistance,
                                         in.lineParameter,
                                         in.lineStyle,
                                         in.lineMinimumWidthPoints,
                                         overviewFade.pixelsPerPoint,
                                         lineDash.unitsPerPoint);
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
    color.rgb *= shadowColorMultiplier(shadow, half(shadowFactor));
    color.rgb = applyHorizonFog(color.rgb, horizonFog, in.worldPos);
    return color;
}
