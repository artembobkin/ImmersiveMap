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
/// and the ribbons class); the fills class drops them: its geometry has a
/// zero side distance and a saturated end parameter, so the analytic
/// coverage is identically 1 and the fields would only be interpolated to
/// be ignored. The classes are separate index segments baked by the parser
/// (`fillsIndexCount`), so a class pass never reads the other's vertices.
constant bool kTileSphereLineFields [[function_constant(1)]];
/// The fills class carries the resolved colour; the ribbons class carries
/// the flat style index instead and the fragment resolves the style itself
/// (tileLineFragmentColor), which cuts a ribbon vertex's interpolants to a
/// third.
constant bool kTileSphereFillClass = !kTileSphereLineFields;

struct SphereVertexOut {
    float4 position [[position]];
    // The morphed surface position the fog distances read; morph only.
    float3 worldPos [[function_constant(kTileSphereFog)]];
    // Fills class: the resolved colour with the zoom fade already folded
    // into the alpha (a function of the style and the frame only).
    half4 color [[function_constant(kTileSphereFillClass)]];
    // Ribbons class: the style index rides flat and the fragment resolves
    // colour, fade and line style itself; only the two genuinely
    // per-vertex line fields interpolate (the longitudinal parameter raw,
    // its decode scale being a style constant).
    uint styleIndex [[flat, function_constant(kTileSphereLineFields)]];
    float lineDistance [[function_constant(kTileSphereLineFields)]];
    float lineParameterRaw [[function_constant(kTileSphereLineFields)]];
};

// The fragment stage's view of SphereVertexOut, without the clip distances.
struct SphereFragmentIn {
    float4 position [[position]];
    float3 worldPos [[function_constant(kTileSphereFog)]];
    half4 color [[function_constant(kTileSphereFillClass)]];
    uint styleIndex [[flat, function_constant(kTileSphereLineFields)]];
    float lineDistance [[function_constant(kTileSphereLineFields)]];
    float lineParameterRaw [[function_constant(kTileSphereLineFields)]];
};

constant float kTileSphereExtent = 4096.0;

// The ground's rank depth: a band at the far plane ordered class first,
// style rank second (GlobeVectorSurfaceDrawer):
//  - the opaque fill layers of one tile shade a pixel once by the topmost
//    opaque layer, submission order free (TBDR hidden surface removal),
//  - the ribbons of one tile pass over every fill of the same tile.
// WHICH tile owns a pixel is not depth's job any more: the tile-priority
// STENCIL decides it (TileSourceStencilPriority; the owner passes write
// the source's mark, every pass tests greaterEqual), the same mechanism
// the flat map uses. The band spans about 2.1e-4 at the far plane, far
// behind the sphere's limb (z about 0.9954 at zoom 6) and everything that
// depth-tests with real geometry (caps, routes, models). The step is about
// 7 float32 ULP at 1.0; z is constant within a draw call. Mirrored by
// GlobeSurfaceDepthRank.swift (pinned by TileClipDistanceContractTests).
constant float kTileSphereLayerDepthStep = 4e-7;
constant float kTileSphereRibbonDepthBand = 257.0 * kTileSphereLayerDepthStep;

/// The tile-local vertex position as a world uv (x east in turns, y the
/// Mercator row). The parser stores render-space positions (y up,
/// 4096 - tileY); the projection wants uv.y = 0 at the tile's north edge.
/// Not clamped: the stitching margins of line geometry lie beyond 0..4096
/// on purpose. The vertex stages never compute the latitude angle from it:
/// the sphere direction comes through globeWorldUVUnitDirection and the
/// flat morph target IS this uv (the Mercator plane), so the old
/// uv -> atan(sinh) -> latitude -> log(tan) -> uv round trip is gone.
static inline float2 tileSphereWorldUv(float2 localPosition,
                                       constant GlobeSurfaceTile& surfaceTile) {
    float2 localUv = float2(localPosition.x, kTileSphereExtent - localPosition.y) / kTileSphereExtent;
    return surfaceTile.uvOrigin + localUv * surfaceTile.uvScale;
}

/// Writes the class's outputs: the fills class resolves its colour here;
/// the ribbons class exports the style index and the raw line fields, and
/// its fragment resolves the style (tileLineFragmentColor).
static inline void tileSphereWriteStyle(thread SphereVertexOut& out,
                                        VertexIn vertexIn,
                                        constant Style* styles,
                                        constant float* lowZoomFadeMasks,
                                        constant LineStyle* lineStyles,
                                        constant StreetPaletteUniform& streetPalette,
                                        constant OverviewFadeUniform& overviewFade) {
    if (kTileSphereLineFields) {
        out.styleIndex = uint(vertexIn.styleIndex);
        out.lineDistance = float(vertexIn.lineDistance) / 127.0;
        out.lineParameterRaw = float(vertexIn.lineParameter);
    } else {
        TileVertexStyle style = tileVertexStyle(vertexIn, styles, lowZoomFadeMasks,
                                                lineStyles, streetPalette);
        out.color = style.color;
        out.color.a *= tileStyleFade(style.lowZoomFadeMask, overviewFade);
    }
}

/// The resting sphere: no morph, no occlusion, no lighting. One composed
/// matrix takes the unit earth direction to clip space; back-face culling
/// removes the far side (every tile triangle is counter-clockwise in render
/// space and the sphere projection does not mirror).
vertex SphereVertexOut tileSpherePureVertexShader(VertexIn vertexIn [[stage_in]],
                                                  constant Style* styles [[buffer(2)]],
                                                  constant float* lowZoomFadeMasks [[buffer(4)]],
                                                  constant LineStyle* lineStyles [[buffer(5)]],
                                                  constant StreetPaletteUniform& streetPalette [[buffer(6)]],
                                                  constant GlobeSurfaceTile& surfaceTile [[buffer(9)]],
                                                  constant GlobeFrameConstants& globeFrame [[buffer(10)]],
                                                  constant OverviewFadeUniform& overviewFade [[buffer(11)]]) {
    float2 localPosition = float2(vertexIn.position.xy);
    float3 unitDirection = globeWorldUVUnitDirection(tileSphereWorldUv(localPosition, surfaceTile));

    SphereVertexOut out;
    out.position = globeFrame.sphereClip * float4(unitDirection, 1.0);
    // The ground carries no geometric depth of its own; its z is the rank
    // band described at kTileSphereLayerDepthStep: class, then style.
    float layerNdcZ = 1.0
        - (float(vertexIn.styleIndex) + 1.0) * kTileSphereLayerDepthStep;
    if (kTileSphereLineFields) {
        layerNdcZ -= kTileSphereRibbonDepthBand;
    }
    out.position.z = layerNdcZ * out.position.w;
    tileSphereWriteStyle(out, vertexIn, styles, lowZoomFadeMasks, lineStyles,
                         streetPalette, overviewFade);
    return out;
}

/// The morph's vertex output: the slot clips plus the unroll's cut, which
/// hides a vertex while its remaining chart travel is long (see
/// GlobeUnroll.h).
struct SphereMorphVertexOut {
    float4 position [[position]];
    // The unroll's cut: hidden while the remaining chart travel is long.
    // The slot clip is gone here too: the morph layers by the same rank
    // depth band as the resting sphere, which is what rejects a coarse
    // substitute wherever a finer tile painted.
    float clipDistance [[clip_distance]] [1];
    float3 worldPos [[function_constant(kTileSphereFog)]];
    half4 color [[function_constant(kTileSphereFillClass)]];
    uint styleIndex [[flat, function_constant(kTileSphereLineFields)]];
    float lineDistance [[function_constant(kTileSphereLineFields)]];
    float lineParameterRaw [[function_constant(kTileSphereLineFields)]];
};

/// The unfurl: the sphere-to-plane unroll of GlobeUnroll.h. The surface
/// stays a convex cap on the growing sphere, back-face culling removes what
/// curls away, and the one clip removes the cut cap around the point
/// opposite the view centre, where the unroll tears. The surface never
/// self-intersects toward the camera, so its z carries no occlusion of its
/// own and the morph draws in the same rank depth band as the resting
/// sphere (source zoom, class, style), with the same layered class passes.
vertex SphereMorphVertexOut tileSphereMorphVertexShader(VertexIn vertexIn [[stage_in]],
                                                   constant Camera& camera [[buffer(1)]],
                                                   constant Style* styles [[buffer(2)]],
                                                   constant float* lowZoomFadeMasks [[buffer(4)]],
                                                   constant LineStyle* lineStyles [[buffer(5)]],
                                                   constant StreetPaletteUniform& streetPalette [[buffer(6)]],
                                                   constant Globe& globe [[buffer(8)]],
                                                   constant GlobeSurfaceTile& surfaceTile [[buffer(9)]],
                                                   constant GlobeFrameConstants& globeFrame [[buffer(10)]],
                                                   constant OverviewFadeUniform& overviewFade [[buffer(11)]]) {
    float2 localPosition = float2(vertexIn.position.xy);
    float2 worldUv = tileSphereWorldUv(localPosition, surfaceTile);
    float3 unitDirection = globeWorldUVUnitDirection(worldUv);
    float3 sphereWorldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    // The flat morph target is the Mercator plane, and the vertex's world
    // uv already IS its Mercator coordinate: no latitude round trip, only
    // the convention change (the uv row runs 0..1 from the north edge, the
    // transition projection wants -1..1 north-positive, clamped the way
    // getYMercNorm clamps to the Mercator range).
    float mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                                globeFrame.mapSize, globeFrame.panMercatorY,
                                                                surfaceTile.referenceWorldX);
    float3 worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                    globe.transition, globe.radius);

    SphereMorphVertexOut out;
    out.position = camera.matrix * float4(worldPosition, 1.0);
    // The rank band replaces the surface's own z, exactly as on the
    // resting sphere (see kTileSphereLayerDepthStep).
    float layerNdcZ = 1.0
        - (float(vertexIn.styleIndex) + 1.0) * kTileSphereLayerDepthStep;
    if (kTileSphereLineFields) {
        layerNdcZ -= kTileSphereRibbonDepthBand;
    }
    out.position.z = layerNdcZ * out.position.w;
    // The unroll's cut: hidden while the remaining chart travel is long.
    out.clipDistance[0] = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                                  globe.transition, globe.radius);
    if (kTileSphereFog) {
        out.worldPos = worldPosition;
    }
    if (kTileSphereLineFields) {
        out.styleIndex = uint(vertexIn.styleIndex);
        out.lineDistance = float(vertexIn.lineDistance) / 127.0;
        out.lineParameterRaw = float(vertexIn.lineParameter);
    } else {
        TileVertexStyle style = tileVertexStyle(vertexIn, styles, lowZoomFadeMasks,
                                                lineStyles, streetPalette);
        out.color = style.color;
        out.color.a *= tileStyleFade(style.lowZoomFadeMask, overviewFade);
    }
    return out;
}

// No shadows on the globe (a flat-world effect), no textures, no lighting,
// no fog: the colour comes from the style and the coverage, on the resting
// sphere and through the morph alike.
fragment half4 tileSphereFragmentShader(SphereFragmentIn in [[stage_in]],
                                        constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                        constant LineDashUniform& lineDash [[buffer(4)]],
                                        constant Style* styles [[buffer(5), function_constant(kTileSphereLineFields)]],
                                        constant float* lowZoomFadeMasks [[buffer(6), function_constant(kTileSphereLineFields)]],
                                        constant LineStyle* lineStyles [[buffer(7), function_constant(kTileSphereLineFields)]],
                                        constant StreetPaletteUniform& streetPalette [[buffer(8), function_constant(kTileSphereLineFields)]]) {
    // The fills class arrives with its final colour (fade folded in the
    // vertex stage); the ribbons class resolves colour, fade and coverage
    // from the flat style index right here.
    half4 color;
    if (kTileSphereLineFields) {
        color = tileLineFragmentColor(in.styleIndex, in.lineDistance, in.lineParameterRaw,
                                      styles, lowZoomFadeMasks, lineStyles, streetPalette,
                                      overviewFade, lineDash);
    } else {
        color = in.color;
    }
    return color;
}
