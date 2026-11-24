// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  TileGrid.metal
//  ImmersiveMap
//
//  The grid of tiles an app's user picks tiles on (TileGridRenderSubsystem):
//  the border of every tile, the fill of a selected one, and each tile's
//  text lying in its plane. A point of the grid is a tile's own uv (u east,
//  v SOUTH, 0 to 1 across the tile), projected the ground's own way on the
//  surface the frame draws (kTileGridSurface), as the layers of the app's
//  data are (Layers.metal):
//
//  - the flat map, from the tile's origin and size in the render world,
//  - the resting sphere, the unit earth direction through the composed
//    sphere matrix,
//  - the unfurl, the sphere-to-plane unroll with its cut.
//
//  A tile is one patch, an instance of a lattice the pipeline holds
//  (TileGridPipeline), so a coarse tile curves with the sphere. The border
//  is not geometry: the fragment stage measures how far the pixel is from
//  the tile's edge on screen and paints the line there, as wide in points
//  at every zoom, each tile the half of the line inside its own edge. The
//  tiles do not overlap, so a pixel of the ground is shaded once. A glyph
//  is a quad whose corners are tile uv, so the text turns, tilts and
//  curves with its tile and grows with it. Everything is blended and
//  unlit, and drawn in the overlay pass, over the finished world and the
//  map's names, untested against any depth: the grid is a tool laid over
//  the map, and nothing the map draws covers a border or a tile's
//  numbers.
//

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"
#include "../../Globe/Shaders/GlobeTileProjection.h"

/// The surface the frame draws: 0 the flat map, 1 the resting sphere, 2
/// the unfurl. Mirrors TileGridPipeline.Surface.
constant int kTileGridSurface [[function_constant(0)]];
constant int kTileGridSurfaceFlat = 0;
constant int kTileGridSurfaceSphere = 1;

// The scale the projection applies to the z of everything real
// (RenderCamera.realDepthScale): the flat surface and the unfurl divide it
// out and apply the grid's own depth, which keeps it within the clip
// volume and is tested against nothing.
constant float kTileGridRealDepthScale = 1.0 - 1536.0 * 3.2e-6;
// The points along a side of the lattice a patch is cut from
// (TileGridPipeline.latticeSide + 1).
constant uint kTileGridLatticePoints = 65;

constant uint kTileGridFlagSelected = 1;
constant uint kTileGridFlagFillOnly = 2;

/// One tile of the frame. Mirrors TileGridTileGPU in TileGridPipeline.swift.
struct TileGridTile {
    /// The tile's south-west corner and its size in the flat render world
    /// (the flat surface).
    float2 flatOrigin;
    float flatSize;
    /// The world x the unfurl unwraps the tile around.
    float referenceWorldX;
    /// The tile's world uv origin (its north-west corner) and size (the
    /// sphere and the unfurl).
    float2 uvOrigin;
    float uvScale;
    uint flags;
};

/// One corner of a glyph. Mirrors TileGridGlyphGPU in TileGridPipeline.swift.
struct TileGridGlyph {
    /// Where the corner lies in its tile.
    float2 tileUV;
    float2 atlasUV;
    /// The tile in the frame's tiles.
    uint tileIndex;
    /// The text fades out as its em gets smaller on screen than this, in
    /// pixels: what it spans in the narrowest tile that shows texts.
    float minimumEmPx;
};

/// The frame's look. Mirrors TileGridFrameUniform in TileGridPipeline.swift.
struct TileGridFrame {
    float4 lineColor;
    float4 selectedFillColor;
    float4 labelColor;
    float4 labelHaloColor;
    /// Half the border's width, in pixels: the half a tile draws.
    float halfLineWidthPx;
    /// The borders fade out as a tile gets narrower on screen than this.
    float minimumTilePx;
    /// The clip-space depth the grid lies at (TileGridDepth).
    float depth;
    /// The atlas's distance range, in texels.
    float atlasDistanceRange;
    /// Atlas texels per em.
    float atlasEmTexels;
    float haloWidthPx;
    /// 1 for the halo draw, 0 for the fill draw.
    float haloPass;
    float _padding;
};

/// A point of the surface in clip space.
struct TileGridClip {
    float4 position;
    /// Negative where the surface hides the point: the far side of the
    /// sphere, the unroll's cut.
    float clipDistance;
};

/// A point of a tile, by its uv, on the frame's surface. The one place the
/// tile's v, which grows south, meets the render world's y, which grows
/// north (TileCoordinateSpace).
static inline TileGridClip tileGridProject(float2 tileUV,
                                           TileGridTile tile,
                                           constant Camera& camera,
                                           constant TileGridFrame& frame,
                                           constant Globe& globe,
                                           constant GlobeFrameConstants& globeFrame) {
    TileGridClip clip;
    if (kTileGridSurface == kTileGridSurfaceFlat) {
        float2 world = tile.flatOrigin + float2(tileUV.x, 1.0 - tileUV.y) * tile.flatSize;
        clip.position = camera.matrix * float4(world, 0.0, 1.0);
        clip.position.z *= frame.depth / kTileGridRealDepthScale;
        clip.clipDistance = 1.0;
        return clip;
    }
    float2 worldUv = tile.uvOrigin + tileUV * tile.uvScale;
    float3 unitDirection = globeWorldUVUnitDirection(worldUv);
    float3 sphereWorldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    if (kTileGridSurface == kTileGridSurfaceSphere) {
        clip.position = globeFrame.sphereClip * float4(unitDirection, 1.0);
        clip.position.z = frame.depth * clip.position.w;
        // The far side of the planet: a patch that crosses the limb is cut
        // where the sphere turns away from the eye.
        float3 sphereNormal = (globeFrame.sphereWorld * float4(unitDirection, 0.0)).xyz;
        clip.clipDistance = dot(normalize(sphereNormal), normalize(camera.eye - sphereWorldPosition));
        return clip;
    }
    float mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                                globeFrame.mapSize, globeFrame.panMercatorY,
                                                                tile.referenceWorldX);
    float3 worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                    globe.transition, globe.radius);
    clip.position = camera.matrix * float4(worldPosition, 1.0);
    clip.position.z *= frame.depth / kTileGridRealDepthScale;
    clip.clipDistance = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                                globe.transition, globe.radius);
    return clip;
}

// MARK: - The patch: the border and the selected fill

struct TileGridPatchOut {
    float4 position [[position]];
    float clipDistance [[clip_distance]] [1];
    float2 tileUV;
    uint flags [[flat]];
};

struct TileGridPatchIn {
    float4 position [[position]];
    float2 tileUV;
    uint flags [[flat]];
};

vertex TileGridPatchOut tileGridPatchVertex(uint vertexID [[vertex_id]],
                                            uint instanceID [[instance_id]],
                                            constant TileGridTile* tiles [[buffer(0)]],
                                            constant Camera& camera [[buffer(1)]],
                                            constant TileGridFrame& frame [[buffer(2)]],
                                            constant Globe& globe [[buffer(8)]],
                                            constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    TileGridTile tile = tiles[instanceID];
    float2 tileUV = float2(float(vertexID % kTileGridLatticePoints), float(vertexID / kTileGridLatticePoints))
        / float(kTileGridLatticePoints - 1);
    TileGridClip clip = tileGridProject(tileUV, tile, camera, frame, globe, globeFrame);
    TileGridPatchOut out;
    out.position = clip.position;
    out.clipDistance[0] = clip.clipDistance;
    out.tileUV = tileUV;
    out.flags = tile.flags;
    return out;
}

fragment half4 tileGridPatchFragment(TileGridPatchIn in [[stage_in]],
                                     constant TileGridFrame& frame [[buffer(0)]]) {
    // How fast each axis of the tile's uv crosses the screen, per pixel:
    // the length of its gradient, so a turned grid keeps its width.
    float perPixelU = max(length(float2(dfdx(in.tileUV.x), dfdy(in.tileUV.x))), 1.0e-9);
    float perPixelV = max(length(float2(dfdx(in.tileUV.y), dfdy(in.tileUV.y))), 1.0e-9);
    float2 toEdge = min(in.tileUV, 1.0 - in.tileUV);
    float edgePx = min(toEdge.x / perPixelU, toEdge.y / perPixelV);
    // The tile's width on screen along the axis the view squeezes most.
    float tilePx = 1.0 / max(perPixelU, perPixelV);

    float line = 1.0 - smoothstep(frame.halfLineWidthPx - 0.5, frame.halfLineWidthPx + 0.5, edgePx);
    line *= smoothstep(0.5 * frame.minimumTilePx, frame.minimumTilePx, tilePx);
    if ((in.flags & kTileGridFlagFillOnly) != 0) {
        line = 0.0;
    }
    float lineAlpha = line * frame.lineColor.a;
    float fillAlpha = (in.flags & kTileGridFlagSelected) != 0 ? frame.selectedFillColor.a : 0.0;

    // The line over the fill, as one straight-alpha colour.
    float alpha = lineAlpha + fillAlpha * (1.0 - lineAlpha);
    float3 color = (frame.lineColor.rgb * lineAlpha + frame.selectedFillColor.rgb * fillAlpha * (1.0 - lineAlpha))
        / max(alpha, 1.0e-5);
    return half4(half3(color), half(alpha));
}

// MARK: - The text

struct TileGridGlyphOut {
    float4 position [[position]];
    float clipDistance [[clip_distance]] [1];
    float2 atlasUV;
    float minimumEmPx [[flat]];
};

struct TileGridGlyphIn {
    float4 position [[position]];
    float2 atlasUV;
    float minimumEmPx [[flat]];
};

vertex TileGridGlyphOut tileGridGlyphVertex(uint vertexID [[vertex_id]],
                                            constant TileGridGlyph* glyphs [[buffer(0)]],
                                            constant Camera& camera [[buffer(1)]],
                                            constant TileGridFrame& frame [[buffer(2)]],
                                            constant TileGridTile* tiles [[buffer(3)]],
                                            constant Globe& globe [[buffer(8)]],
                                            constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    TileGridGlyph glyph = glyphs[vertexID];
    TileGridClip clip = tileGridProject(glyph.tileUV, tiles[glyph.tileIndex], camera, frame, globe, globeFrame);
    TileGridGlyphOut out;
    out.position = clip.position;
    out.clipDistance[0] = clip.clipDistance;
    out.atlasUV = glyph.atlasUV;
    out.minimumEmPx = glyph.minimumEmPx;
    return out;
}

/// The glyph's distance fields in screen pixels: the multi-channel field
/// for the fill, the true field in the alpha for the halo, which reaches
/// past the glyph. The pixel range comes from the uv derivatives, so it
/// follows the glyph's size on screen through the perspective and the
/// zoom (surfaceLabelFragment in SurfaceLabel.metal).
fragment half4 tileGridGlyphFragment(TileGridGlyphIn in [[stage_in]],
                                     texture2d<half> atlasTexture [[texture(0)]],
                                     constant TileGridFrame& frame [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    half4 atlasSample = atlasTexture.sample(textureSampler, in.atlasUV);
    half3 msdf = atlasSample.rgb;
    float msdfDistance = float(max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b))) - 0.5;
    float sdfDistance = float(atlasSample.a) - 0.5;
    float2 textureSize = float2(atlasTexture.get_width(), atlasTexture.get_height());
    float2 unitRange = float2(frame.atlasDistanceRange) / textureSize;
    float2 screenTextureSize = 1.0 / max(fwidth(in.atlasUV), float2(1.0e-6));
    float screenPxRange = max(0.5 * dot(unitRange, screenTextureSize), 1.0);
    // Screen pixels per atlas texel, and so per em.
    float pixelsPerTexel = screenPxRange / max(frame.atlasDistanceRange, 1.0);
    float emPx = pixelsPerTexel * frame.atlasEmTexels;

    float coverage;
    float4 color;
    if (frame.haloPass > 0.5) {
        // The halo reaches past the glyph by its width, bounded by the
        // distance field's support.
        float haloPx = min(frame.haloWidthPx, max(0.5 * screenPxRange - 0.5, 0.0));
        coverage = haloPx > 0.0 ? smoothstep(-haloPx - 0.5, -haloPx + 0.5, sdfDistance * screenPxRange) : 0.0;
        color = frame.labelHaloColor;
    } else {
        coverage = smoothstep(-0.5, 0.5, msdfDistance * screenPxRange);
        color = frame.labelColor;
    }
    // Far tiles under a tilt: the text goes before it turns to noise.
    coverage *= smoothstep(0.5 * in.minimumEmPx, in.minimumEmPx, emPx);
    return half4(half3(color.rgb), half(coverage * color.a));
}
