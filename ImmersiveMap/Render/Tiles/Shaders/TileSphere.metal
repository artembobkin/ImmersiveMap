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
#include "../../Shaders/Globe/GlobeSurfaceShading.h"

/// Per-draw tile identity for the projection; the layout mirrors
/// GlobeSurfaceTileUniform.swift (pinned by GlobeVectorSurfaceUniformLayoutTests).
struct GlobeSurfaceTile {
    /// The source tile the vertices are local to (x, y, z).
    int3 tile;
    /// Radial lift of the sphere position, as a fraction of the radius, and
    /// of the flat morph target along +z as the same fraction of the radius.
    /// The placeholder grid under this geometry is a different chord of the
    /// same sphere (latitude-linear rows against Mercator-linear triangles),
    /// so without a lift the two would z-fight; lifted above both chord sags
    /// (GlobeSurfaceLift), the geometry passes the depth test everywhere the
    /// placeholder wrote it and never writes depth of its own.
    float lift;
};

struct SphereVertexOut {
    float4 position [[position]];
    // 0..3: the placeIn slot edges (tileLocalClipDistances). 4: the horizon,
    // positive on the camera-facing side of the sphere; the rasterizer clips
    // the far side away geometrically, so nothing on the back of the planet
    // is ever shaded and no fragment needs a discard. Off once the unfurl
    // has flattened the surface (the same gate as globePointPassesVisibility).
    float clipDistance [[clip_distance]] [5];
    // The unlifted morphed surface position: fog, view angle and the
    // horizon test all read the true surface, not the lifted one.
    float3 worldPos;
    float3 normal;
    float3 earthNormal;
    float transition;
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
    float3 worldPos;
    float3 normal;
    float3 earthNormal;
    float transition;
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
                                              constant GlobeSurfaceTile& surfaceTile [[buffer(9)]]) {
    // The parser stores render-space positions (y up, 4096 - tileY); the
    // projection wants uv.y = 0 at the tile's north edge. Not clamped: the
    // stitching margins of line geometry lie beyond 0..4096 on purpose.
    float2 localPosition = float2(vertexIn.position.xy);
    float2 localUv = float2(localPosition.x, kTileSphereExtent - localPosition.y) / kTileSphereExtent;
    GlobeSurfaceProjection projection = globeProjectTileUVDetailed(localUv, surfaceTile.tile, camera, globe);

    float3 globeCenter = float3(0.0, 0.0, -globe.radius);
    float3 liftedSphere = globeCenter + (projection.sphereWorldPosition - globeCenter) * (1.0 + surfaceTile.lift);
    float3 liftedFlat = projection.flatWorldPosition + float3(0.0, 0.0, surfaceTile.lift * globe.radius);
    float3 liftedPosition = mix(liftedSphere, liftedFlat, projection.localTransition);

    SphereVertexOut out;
    out.position = camera.matrix * float4(liftedPosition, 1.0);
    tileLocalClipDistances(localPosition, localClipBounds, out.clipDistance);
    float3 toCamera = camera.eye - globeCenter;
    float horizonDistance = dot(projection.worldPosition - globeCenter, toCamera)
        - globeVisibilityHorizonThreshold(globe);
    out.clipDistance[4] = globe.transition >= 0.95 ? 1.0 : horizonDistance;
    out.worldPos = projection.worldPosition;
    out.normal = projection.normal;
    out.earthNormal = projection.earthNormal;
    out.transition = globe.transition;
    TileVertexStyle style = tileVertexStyle(vertexIn, styles, lowZoomFadeMasks, lineStyles, streetPalette);
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
    half4 shaded = globeSurfaceShade(color, in.worldPos, in.normal, in.earthNormal, in.transition,
                                     camera, earthScene, horizonFog, atmosphere, tone);
    shaded.a = color.a;
    return shaded;
}
