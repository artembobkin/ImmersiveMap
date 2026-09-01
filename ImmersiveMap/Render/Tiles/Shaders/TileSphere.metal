// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileSphere.metal
//  ImmersiveMap
//
//  The tile geometry of the globe, drawn straight onto the sphere: the same
//  vertices, styles, line coverage and fades as the flat surface
//  (TileShading.h). Two vertex stages, one per world:
//
//  - tileSpherePureVertexShader draws the resting sphere. No morph, no
//    occlusion, no lighting: the unit earth direction goes through one
//    composed matrix (camera x translate x pan rotation x radius, built on
//    the CPU per frame) straight to clip space, and the far side of the
//    planet is removed by back-face culling alone.
//  - tileSphereMorphVertexShader draws the unfurl: the sphere-to-plane
//    unroll (GlobeUnroll.h), under which the surface never intersects the
//    planet or itself, so it needs no occlusion clip either. It alone
//    carries the flat morph target and the horizon fog.
//
//  Everything shared lives in headers: the projection in
//  GlobeTileProjection.h / GlobeUnroll.h, the styles and coverage in
//  TileShading.h.
//

#include <metal_stdlib>
using namespace metal;
#include "TileShading.h"
#include "../../Shaders/Globe/GlobeTileProjection.h"

/// Per-draw tile identity for the projection, precomputed on the CPU so the
/// vertex stage does no per-vertex pow(2, z); the layout mirrors
/// GlobeSurfaceTileUniform.swift (pinned by GlobeVectorSurfaceUniformLayoutTests).
struct GlobeSurfaceTile {
    /// World uv of the tile's north-west corner (x east, y the Mercator row).
    float2 uvOrigin;
    /// Tile-local uv to world uv: 1 / 2^z.
    float uvScale;
    /// The normalized world x the flat morph target unwraps around: the
    /// tile's centre, (x + 0.5) / 2^z (see globeTransitionFlatWorldX).
    float referenceWorldX;
};

/// True while the sphere unfurls: the fragment applies the horizon fog,
/// whose strength is the transition. False on the resting sphere, where the
/// style colour is final. The fog input (the world position) exists only in
/// the fogged variant.
constant bool kTileSphereFog [[function_constant(0)]];

/// True when the pass carries the line fields (the morph's combined pass
/// and the ribbons class); the fills class of a split pass drops them: its
/// geometry has a zero side distance and a saturated end parameter, so the
/// analytic coverage is identically 1 and the fields would only be
/// interpolated to be ignored.
constant bool kTileSphereLineFields [[function_constant(1)]];

/// The ground bucket draws as two class passes on the resting sphere: a
/// split pipeline keeps exactly one class and degenerates the other's
/// primitives whole (NaN position), which isolates the fills from the line
/// ribbons (GlobeVectorSurfaceDrawer). The morph keeps the single combined
/// pass.
constant bool kTileSphereSplitPass [[function_constant(2)]];
constant bool kTileSphereLinesClass [[function_constant(3)]];

struct SphereVertexOut {
    float4 position [[position]];
    // The placeIn slot edges (tileLocalClipDistances): a retained substitute
    // is clipped to the slot it stands in for by the rasterizer.
    float clipDistance [[clip_distance]] [4];
    // The morphed surface position the fog distances read; morph only.
    float3 worldPos [[function_constant(kTileSphereFog)]];
    half4 color;
    half lowZoomFadeMask;
    float lineDistance [[function_constant(kTileSphereLineFields)]];
    float lineParameter [[function_constant(kTileSphereLineFields)]];
    half4 lineStyle [[function_constant(kTileSphereLineFields)]];
    half lineMinimumWidthPoints [[function_constant(kTileSphereLineFields)]];
    half lineMaximumWidthPoints [[function_constant(kTileSphereLineFields)]];
    half lineDashInTileUnits [[function_constant(kTileSphereLineFields)]];
};

// The fragment stage's view of SphereVertexOut, without the clip distances.
struct SphereFragmentIn {
    float4 position [[position]];
    float3 worldPos [[function_constant(kTileSphereFog)]];
    half4 color;
    half lowZoomFadeMask;
    float lineDistance [[function_constant(kTileSphereLineFields)]];
    float lineParameter [[function_constant(kTileSphereLineFields)]];
    half4 lineStyle [[function_constant(kTileSphereLineFields)]];
    half lineMinimumWidthPoints [[function_constant(kTileSphereLineFields)]];
    half lineMaximumWidthPoints [[function_constant(kTileSphereLineFields)]];
    half lineDashInTileUnits [[function_constant(kTileSphereLineFields)]];
};

constant float kTileSphereExtent = 4096.0;

/// The tile-local vertex position as geographic coordinates. The parser
/// stores render-space positions (y up, 4096 - tileY); the projection wants
/// uv.y = 0 at the tile's north edge. Not clamped: the stitching margins of
/// line geometry lie beyond 0..4096 on purpose.
static inline float2 tileSphereLatLon(float2 localPosition,
                                      constant GlobeSurfaceTile& surfaceTile) {
    float2 localUv = float2(localPosition.x, kTileSphereExtent - localPosition.y) / kTileSphereExtent;
    float2 worldUv = surfaceTile.uvOrigin + localUv * surfaceTile.uvScale;
    return globeWorldUVLatLon(worldUv);
}

/// Copies the resolved style into the vertex output; the line fields only
/// when the pass carries them.
static inline void tileSphereWriteStyle(thread SphereVertexOut& out, TileVertexStyle style) {
    out.color = style.color;
    out.lowZoomFadeMask = style.lowZoomFadeMask;
    if (kTileSphereLineFields) {
        out.lineDistance = style.lineDistance;
        out.lineParameter = style.lineParameter;
        out.lineStyle = style.lineStyle;
        out.lineMinimumWidthPoints = style.lineMinimumWidthPoints;
        out.lineMaximumWidthPoints = style.lineMaximumWidthPoints;
        out.lineDashInTileUnits = style.lineDashInTileUnits;
    }
}

/// The resting sphere: no morph, no occlusion, no lighting. One composed
/// matrix takes the unit earth direction to clip space; back-face culling
/// removes the far side (every tile triangle is counter-clockwise in render
/// space and the sphere projection does not mirror).
vertex SphereVertexOut tileSpherePureVertexShader(VertexIn vertexIn [[stage_in]],
                                                  constant Style* styles [[buffer(2)]],
                                                  constant float& layerNdcZ [[buffer(3)]],
                                                  constant float* lowZoomFadeMasks [[buffer(4)]],
                                                  constant LineStyle* lineStyles [[buffer(5)]],
                                                  constant StreetPaletteUniform& streetPalette [[buffer(6)]],
                                                  constant float4& localClipBounds [[buffer(7)]],
                                                  constant GlobeSurfaceTile& surfaceTile [[buffer(9)]],
                                                  constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    float2 localPosition = float2(vertexIn.position.xy);
    float2 latLon = tileSphereLatLon(localPosition, surfaceTile);
    float3 unitDirection = globeSphereUnitDirection(latLon.x, latLon.y);

    SphereVertexOut out;
    out.position = globeFrame.sphereClip * float4(unitDirection, 1.0);
    // The ground carries no geometric depth of its own (nothing on the
    // sphere compares against it); its z is the per-draw layer rank in a
    // band at the far plane, so the opaque layers can draw front-to-back
    // under a depth test and a pixel is shaded once by its topmost opaque
    // layer (GlobeVectorSurfaceDrawer).
    out.position.z = layerNdcZ * out.position.w;
    tileLocalClipDistances(localPosition, localClipBounds, out.clipDistance);
    // A split pipeline keeps only its own class. The class is a property of
    // the geometry, not the style (a fill shares its style with its
    // decoration): extruded line ribbons carry a non-zero per-vertex side
    // distance, fills carry zero, and no triangle mixes the two. A NaN
    // position degenerates the whole primitive before rasterization.
    if (kTileSphereSplitPass) {
        bool isLine = vertexIn.lineDistance != 0;
        if (isLine != kTileSphereLinesClass) {
            out.position = float4(as_type<float>(0x7FC00000u));
        }
    }
    tileSphereWriteStyle(out, tileVertexStyle(vertexIn, styles, lowZoomFadeMasks, lineStyles, streetPalette));
    return out;
}

/// The morph's vertex output: the slot clips plus the unroll's cut, which
/// hides a vertex while its remaining chart travel is long (see
/// GlobeUnroll.h).
struct SphereMorphVertexOut {
    float4 position [[position]];
    // 0..3: the placeIn slot edges; 4: the unroll's cut.
    float clipDistance [[clip_distance]] [5];
    float3 worldPos [[function_constant(kTileSphereFog)]];
    half4 color;
    half lowZoomFadeMask;
    float lineDistance [[function_constant(kTileSphereLineFields)]];
    float lineParameter [[function_constant(kTileSphereLineFields)]];
    half4 lineStyle [[function_constant(kTileSphereLineFields)]];
    half lineMinimumWidthPoints [[function_constant(kTileSphereLineFields)]];
    half lineMaximumWidthPoints [[function_constant(kTileSphereLineFields)]];
    half lineDashInTileUnits [[function_constant(kTileSphereLineFields)]];
};

/// The unfurl: the sphere-to-plane unroll of GlobeUnroll.h. The surface
/// stays a convex cap on the growing sphere, back-face culling removes what
/// curls away, and the fifth clip removes the cut cap around the point
/// opposite the view centre, where the unroll tears.
vertex SphereMorphVertexOut tileSphereMorphVertexShader(VertexIn vertexIn [[stage_in]],
                                                   constant Camera& camera [[buffer(1)]],
                                                   constant Style* styles [[buffer(2)]],
                                                   constant float* lowZoomFadeMasks [[buffer(4)]],
                                                   constant LineStyle* lineStyles [[buffer(5)]],
                                                   constant StreetPaletteUniform& streetPalette [[buffer(6)]],
                                                   constant float4& localClipBounds [[buffer(7)]],
                                                   constant Globe& globe [[buffer(8)]],
                                                   constant GlobeSurfaceTile& surfaceTile [[buffer(9)]],
                                                   constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    float2 localPosition = float2(vertexIn.position.xy);
    float2 latLon = tileSphereLatLon(localPosition, surfaceTile);
    float3 unitDirection = globeSphereUnitDirection(latLon.x, latLon.y);
    float3 sphereWorldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    float3 flatWorldPosition = globeFlatWorldPosition(latLon.x, latLon.y, globe,
                                                      globeFrame.mapSize, globeFrame.panMercatorY,
                                                      surfaceTile.referenceWorldX);
    float3 worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition.xy,
                                                    globe.transition, globe.radius);

    SphereMorphVertexOut out;
    out.position = camera.matrix * float4(worldPosition, 1.0);
    tileLocalClipDistances(localPosition, localClipBounds, out.clipDistance);
    // The unroll's cut: hidden while the remaining chart travel is long.
    out.clipDistance[4] = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition.xy,
                                                  globe.transition, globe.radius);
    if (kTileSphereFog) {
        out.worldPos = worldPosition;
    }
    TileVertexStyle style = tileVertexStyle(vertexIn, styles, lowZoomFadeMasks, lineStyles, streetPalette);
    out.color = style.color;
    out.lowZoomFadeMask = style.lowZoomFadeMask;
    if (kTileSphereLineFields) {
        out.lineDistance = style.lineDistance;
        out.lineParameter = style.lineParameter;
        out.lineStyle = style.lineStyle;
        out.lineMinimumWidthPoints = style.lineMinimumWidthPoints;
        out.lineMaximumWidthPoints = style.lineMaximumWidthPoints;
        out.lineDashInTileUnits = style.lineDashInTileUnits;
    }
    return out;
}

static inline TileVertexStyle tileSphereFragmentStyle(SphereFragmentIn in) {
    TileVertexStyle style;
    style.color = in.color;
    style.lowZoomFadeMask = in.lowZoomFadeMask;
    style.lineDistance = in.lineDistance;
    style.lineParameter = in.lineParameter;
    style.lineStyle = in.lineStyle;
    style.lineMinimumWidthPoints = in.lineMinimumWidthPoints;
    style.lineMaximumWidthPoints = in.lineMaximumWidthPoints;
    style.lineDashInTileUnits = in.lineDashInTileUnits;
    return style;
}

// No shadows on the globe (a flat-world effect), no textures, no lighting:
// the colour comes from the style and the coverage. The morph variant adds
// only the horizon fog, whose strength is the transition, so the morph and
// the plane are fogged identically at the surface swap.
fragment half4 tileSphereFragmentShader(SphereFragmentIn in [[stage_in]],
                                        constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                        constant HorizonFog& horizonFog [[buffer(2)]],
                                        constant LineDashUniform& lineDash [[buffer(4)]]) {
    half4 color;
    if (kTileSphereLineFields) {
        color = tileGroundColor(tileSphereFragmentStyle(in), overviewFade, lineDash);
    } else {
        // The fills class: coverage is identically 1, only the zoom fade
        // scales the style colour.
        color = in.color;
        color.a *= tileStyleFade(in.lowZoomFadeMask, overviewFade);
    }
    if (kTileSphereFog) {
        color.rgb = applyHorizonFog(color.rgb, horizonFog, in.worldPos);
    }
    return color;
}
