// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileSphere.metal
//  ImmersiveMap
//
//  The tile geometry of the globe, drawn straight onto the sphere: the same
//  vertices, styles, line coverage and fades as the flat surface
//  (TileShading.h), projected per vertex through the globe's own surface
//  morph (GlobeTileProjection.h) and lit like the placeholder grid under it
//  (GlobeSurfaceShading.h). No raster intermediate: nothing to re-bake when
//  the zoom moves, and every line is drawn at the screen's own density.
//

#include <metal_stdlib>
using namespace metal;
#include "TileShading.h"
#include "../../Shaders/Globe/GlobeTileProjection.h"
#include "../../Shaders/Globe/GlobeOcclusion.h"
#include "../../Shaders/Globe/GlobeSurfaceShading.h"

/// Per-draw tile identity for the projection; the layout mirrors
/// GlobeSurfaceTileUniform.swift (pinned by GlobeVectorSurfaceUniformLayoutTests).
struct GlobeSurfaceTile {
    /// The source tile the vertices are local to (x, y, z).
    int3 tile;
};

/// True (the default pipeline) lights every fragment inline through
/// globeSurfaceShade. False is the deferred-lighting world: the layers
/// blend unlit and the globeSurfaceLighting pass applies the light once
/// per pixel (GlobeSurfaceLighting.metal), which is exact while the
/// lighting is affine (transition 0, tone depth 0, fog strength 0). The
/// lighting inputs below exist only in the lit variant: the unlit layers
/// neither export, interpolate nor load them.
constant bool kTileSphereLitInline [[function_constant(0)]];

/// True on the pure sphere (transition 0, gated per frame by
/// GlobeSphereVertexPath): the vertex stage folds away the flat morph
/// target, the unfurl phase and the mix, and the surface is the sphere
/// itself. False while the sphere unfurls.
constant bool kTileSpherePureSphere [[function_constant(1)]];

/// The ground bucket can draw as two class passes on the pure sphere: a
/// split pipeline keeps exactly one class and clips the other's primitives
/// whole, which isolates the fills from the line ribbons so the globe
/// performance work can toggle either on its own
/// (GlobeVectorSurfaceDrawer). The morph and the flat surface keep the
/// single combined pass.
constant bool kTileSphereSplitPass [[function_constant(2)]];
constant bool kTileSphereLinesClass [[function_constant(3)]];

struct SphereVertexOut {
    float4 position [[position]];
    // 0..3: the placeIn slot edges (tileLocalClipDistances). 4: the sphere
    // as an occluder (globeOcclusionClearance), positive where the eye sees
    // the vertex past the planet's edge or in front of it; the rasterizer
    // clips everything the planet hides, so nothing on the back of the
    // planet is ever shaded and no fragment needs a discard. On the pure
    // sphere this is the horizon; while the sphere unfurls it is what hides
    // the far side morphing through the planet's interior, which back-face
    // culling alone cannot (a chord turns front-facing before it is out).
    float clipDistance [[clip_distance]] [5];
    // The morphed surface position: fog, view angle and the horizon test
    // read it. Lit variant only, like the three below.
    float3 worldPos [[function_constant(kTileSphereLitInline)]];
    float3 normal [[function_constant(kTileSphereLitInline)]];
    float3 earthNormal [[function_constant(kTileSphereLitInline)]];
    float transition [[function_constant(kTileSphereLitInline)]];
    half4 color;
    half lowZoomFadeMask;
    float lineDistance;
    float lineParameter;
    half4 lineStyle;
    half lineMinimumWidthPoints;
    half lineMaximumWidthPoints;
    half lineDashInTileUnits;
};

// The fragment stage's view of SphereVertexOut, without the clip distances.
struct SphereFragmentIn {
    float4 position [[position]];
    float3 worldPos [[function_constant(kTileSphereLitInline)]];
    float3 normal [[function_constant(kTileSphereLitInline)]];
    float3 earthNormal [[function_constant(kTileSphereLitInline)]];
    float transition [[function_constant(kTileSphereLitInline)]];
    half4 color;
    half lowZoomFadeMask;
    float lineDistance;
    float lineParameter;
    half4 lineStyle;
    half lineMinimumWidthPoints;
    half lineMaximumWidthPoints;
    half lineDashInTileUnits;
};

constant float kTileSphereExtent = 4096.0;

vertex SphereVertexOut tileSphereVertexShader(VertexIn vertexIn [[stage_in]],
                                              constant Camera& camera [[buffer(1)]],
                                              constant Style* styles [[buffer(2)]],
                                              constant float* lowZoomFadeMasks [[buffer(4)]],
                                              constant LineStyle* lineStyles [[buffer(5)]],
                                              constant StreetPaletteUniform& streetPalette [[buffer(6)]],
                                              constant float4& localClipBounds [[buffer(7)]],
                                              constant Globe& globe [[buffer(8)]],
                                              constant GlobeSurfaceTile& surfaceTile [[buffer(9)]],
                                              constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    // The parser stores render-space positions (y up, 4096 - tileY); the
    // projection wants uv.y = 0 at the tile's north edge. Not clamped: the
    // stitching margins of line geometry lie beyond 0..4096 on purpose.
    float2 localPosition = float2(vertexIn.position.xy);
    float2 localUv = float2(localPosition.x, kTileSphereExtent - localPosition.y) / kTileSphereExtent;
    GlobeSurfaceProjection projection = globeProjectTileUVDetailed(localUv, surfaceTile.tile, camera, globe,
                                                                   globeFrame, kTileSpherePureSphere);

    // Exactly the surface position the placeholder grid morphs through: the
    // geometry is not depth-tested against the grid (its extent is the five
    // clip distances below plus back-face culling, and nothing drawn before
    // it on the sphere occludes it), so it sits on the sphere itself rather
    // than on a shell lifted above the grid's chords.
    SphereVertexOut out;
    out.position = projection.clip;
    tileLocalClipDistances(localPosition, localClipBounds, out.clipDistance);
    out.clipDistance[4] = globeOcclusionClearance(projection.worldPosition, camera, globe);
    if (kTileSphereLitInline) {
        out.worldPos = projection.worldPosition;
        out.normal = projection.normal;
        out.earthNormal = projection.earthNormal;
        out.transition = globe.transition;
    }
    TileVertexStyle style = tileVertexStyle(vertexIn, styles, lowZoomFadeMasks, lineStyles, streetPalette);
    // A split pipeline keeps only its own class. The class is a property of
    // the geometry, not the style (a fill shares its style with its
    // decoration, so the style's edge threshold marks both): extruded line
    // ribbons carry a non-zero per-vertex side distance, fills carry zero,
    // and no triangle mixes the two.
    if (kTileSphereSplitPass) {
        bool isLine = vertexIn.lineDistance != 0;
        if (isLine != kTileSphereLinesClass) {
            out.clipDistance[4] = -1.0;
        }
    }
    out.color = style.color;
    out.lowZoomFadeMask = style.lowZoomFadeMask;
    out.lineDistance = style.lineDistance;
    out.lineParameter = style.lineParameter;
    out.lineStyle = style.lineStyle;
    out.lineMinimumWidthPoints = style.lineMinimumWidthPoints;
    out.lineMaximumWidthPoints = style.lineMaximumWidthPoints;
    out.lineDashInTileUnits = style.lineDashInTileUnits;
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

// No shadows on the globe (a flat-world effect), no textures: the colour
// comes from the style and the coverage, the light from the sphere.
fragment half4 tileSphereFragmentShader(SphereFragmentIn in [[stage_in]],
                                        constant OverviewFadeUniform& overviewFade [[buffer(0)]],
                                        constant HorizonFog& horizonFog [[buffer(2)]],
                                        constant LineDashUniform& lineDash [[buffer(4)]],
                                        constant Camera& camera [[buffer(5)]],
                                        constant EarthScene& earthScene [[buffer(6)]],
                                        constant GlobeAtmosphere& atmosphere [[buffer(7)]],
                                        constant GlobeSurfaceTone& tone [[buffer(8)]]) {
    half4 color = tileGroundColor(tileSphereFragmentStyle(in), overviewFade, lineDash);
    if (!kTileSphereLitInline) {
        return color;
    }
    half4 shaded = globeSurfaceShade(color, in.worldPos, in.normal, in.earthNormal, in.transition,
                                     camera, earthScene, horizonFog, atmosphere, tone);
    shaded.a = color.a;
    return shaded;
}
