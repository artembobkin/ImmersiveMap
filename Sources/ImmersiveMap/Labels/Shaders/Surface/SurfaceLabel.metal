// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  SurfaceLabel.metal
//  ImmersiveMap
//
//  The labels painted on the map (LabelPlacement.surface): glyph quads baked
//  as an anchor in the tile's render units and offsets in points, scaled by
//  the frame into tile units and projected exactly like the ground they lie
//  on. The scale is the map's, floored where the ground is small on screen
//  so the text never draws under its point size.
//  Three vertex stages, one per surface, each the ground's own projection:
//
//  - surfaceLabelFlatVertex: the flat map, through the source's model
//    matrix (Tile.metal).
//  - surfaceLabelSphereVertex: the resting sphere, the unit earth direction
//    through the composed sphere matrix (tileSpherePureVertexShader).
//  - surfaceLabelMorphVertex: the unfurl, the sphere-to-plane unroll with
//    its cut (tileSphereMorphVertexShader).
//
//  The z of every stage is one constant depth in the ground's far-plane
//  band, nearer than the ground and the roads (SurfaceLabelDepth), so the
//  text lies over the ground while every building and model stays in
//  front of it. A label draws twice, its halo first and then its fill,
//  blended and never written to depth, so a glyph's halo cannot cover the
//  fill of its neighbour.
//

#include <metal_stdlib>
using namespace metal;
#include "../../../Render/Shaders/Shared/RenderUniforms.h"
#include "../../../Globe/Shaders/GlobeTileProjection.h"

struct SurfaceLabelVertexIn {
    /// The label's anchor in tile render units.
    float2 anchor [[attribute(0)]];
    float2 uv [[attribute(1)]];
    /// The glyph corner's offset from the anchor in points.
    float2 offsetPoints [[attribute(2)]];
};

/// Per-draw tile identity of the sphere stages; mirrors
/// GlobeSurfaceTileUniform.swift (the sphere ground's GlobeSurfaceTile).
struct SurfaceLabelSphereTile {
    float2 uvOrigin;
    float uvScale;
    float referenceWorldX;
};

/// Per-draw label state; mirrors SurfaceLabelDrawUniform.swift.
struct SurfaceLabelDraw {
    float4 fillColor;
    float4 strokeColor;
    /// The halo's width in atlas texels: the style's halo in ems times the
    /// atlas em, so the halo scales with the text on screen.
    float haloAtlasTexels;
    /// The clip-space depth the text sits at (SurfaceLabelDepth).
    float depth;
    /// 1 for the halo draw, 0 for the fill draw.
    float haloPass;
    /// Tile units per point of the text as the map scales it this frame
    /// (SurfaceLabelScale).
    float tileUnitsPerPoint;
    float2 viewportSizePx;
    float pixelsPerPoint;
    float _padding;
};

struct SurfaceLabelVertexOut {
    float4 position [[position]];
    float2 uv;
    float clipDistance [[clip_distance]] [1];
};

struct SurfaceLabelFragmentIn {
    float4 position [[position]];
    float2 uv;
};

constant float kSurfaceLabelTileExtent = 4096.0;
// The camera's near plane in view units, the cut the flat ground makes
// (kFlatCameraNearPlane in Tile.metal).
constant float kSurfaceLabelNearPlane = 0.01;
// The atlas's distance range in texels (TextShader.metal).
constant float kSurfaceLabelDistanceRange = 24.0;
// How far the scale probe reaches from the anchor, in points of the map's
// own scale: far enough for the float projection to resolve, short
// enough to stay on the anchor's piece of the surface.
constant float kSurfaceLabelProbePoints = 16.0;

static inline float2 surfaceLabelWorldUv(float2 localPosition, constant SurfaceLabelSphereTile& tile) {
    float2 localUv = float2(localPosition.x, kSurfaceLabelTileExtent - localPosition.y) / kSurfaceLabelTileExtent;
    return tile.uvOrigin + localUv * tile.uvScale;
}

/// A point of the surface in clip space, with the clip distance its
/// surface cuts it by.
struct SurfaceLabelClip {
    float4 position;
    float clipDistance;
};

/// Screen pixels per tile unit around the anchor: the longer of the two
/// axes, so a tilt that foreshortens one does not count as a small ground.
/// Zero when the anchor or a probe is behind the camera.
static inline float surfaceLabelPixelsPerUnit(float4 anchorClip, float4 alongX, float4 alongY,
                                              float probeUnits, constant SurfaceLabelDraw& draw) {
    if (anchorClip.w <= kSurfaceLabelNearPlane || alongX.w <= kSurfaceLabelNearPlane
        || alongY.w <= kSurfaceLabelNearPlane) {
        return 0.0;
    }
    float2 anchorScreen = anchorClip.xy / anchorClip.w;
    float2 halfViewport = draw.viewportSizePx * 0.5;
    float spanX = length((alongX.xy / alongX.w - anchorScreen) * halfViewport);
    float spanY = length((alongY.xy / alongY.w - anchorScreen) * halfViewport);
    return max(spanX, spanY) / probeUnits;
}

/// Tile units per point of the text at this frame: the map's own scale,
/// but never smaller on screen than the style's point size. Every vertex
/// of a label measures at the same anchor, so the label scales whole.
static inline float surfaceLabelUnitsPerPoint(float pixelsPerUnit, constant SurfaceLabelDraw& draw) {
    if (pixelsPerUnit <= 0.0) {
        return draw.tileUnitsPerPoint;
    }
    return max(draw.tileUnitsPerPoint, draw.pixelsPerPoint / pixelsPerUnit);
}

static inline SurfaceLabelVertexOut surfaceLabelOutput(SurfaceLabelClip clip, float2 uv,
                                                       constant SurfaceLabelDraw& draw) {
    SurfaceLabelVertexOut out;
    out.position = clip.position;
    out.position.z = draw.depth * out.position.w;
    out.uv = uv;
    out.clipDistance[0] = clip.clipDistance;
    return out;
}

// Each surface's projection of a tile-local point, the ground's own.

static inline SurfaceLabelClip surfaceLabelFlatClip(float2 local,
                                                    constant Camera& camera,
                                                    constant float4x4& modelMatrix) {
    SurfaceLabelClip clip;
    clip.position = camera.matrix * (modelMatrix * float4(local, 0.0, 1.0));
    // The depth is the band's, so the z clip cuts nothing at the near
    // plane: the clip distance does, as on the ground.
    clip.clipDistance = clip.position.w - kSurfaceLabelNearPlane;
    return clip;
}

static inline SurfaceLabelClip surfaceLabelSphereClip(float2 local,
                                                      constant SurfaceLabelSphereTile& tile,
                                                      constant GlobeFrameConstants& globeFrame) {
    SurfaceLabelClip clip;
    float3 unitDirection = globeWorldUVUnitDirection(surfaceLabelWorldUv(local, tile));
    clip.position = globeFrame.sphereClip * float4(unitDirection, 1.0);
    // The far side of the planet goes to back-face culling, as the
    // ground's does.
    clip.clipDistance = 1.0;
    return clip;
}

static inline SurfaceLabelClip surfaceLabelMorphClip(float2 local,
                                                     constant Camera& camera,
                                                     constant Globe& globe,
                                                     constant SurfaceLabelSphereTile& tile,
                                                     constant GlobeFrameConstants& globeFrame) {
    float2 worldUv = surfaceLabelWorldUv(local, tile);
    float3 unitDirection = globeWorldUVUnitDirection(worldUv);
    float3 sphereWorldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    float mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                                globeFrame.mapSize, globeFrame.panMercatorY,
                                                                tile.referenceWorldX);
    float3 worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                    globe.transition, globe.radius);
    SurfaceLabelClip clip;
    clip.position = camera.matrix * float4(worldPosition, 1.0);
    clip.clipDistance = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                                globe.transition, globe.radius);
    return clip;
}

// The three stages: measure the scale at the anchor, then place the glyph
// corner at its offset from it. PROJECT is the surface's projection.
#define SURFACE_LABEL_VERTEX_BODY(PROJECT) \
    float probeUnits = draw.tileUnitsPerPoint * kSurfaceLabelProbePoints; \
    float pixelsPerUnit = surfaceLabelPixelsPerUnit(PROJECT(in.anchor).position, \
                                                    PROJECT(in.anchor + float2(probeUnits, 0.0)).position, \
                                                    PROJECT(in.anchor + float2(0.0, probeUnits)).position, \
                                                    probeUnits, draw); \
    float2 local = in.anchor + in.offsetPoints * surfaceLabelUnitsPerPoint(pixelsPerUnit, draw); \
    return surfaceLabelOutput(PROJECT(local), in.uv, draw);

vertex SurfaceLabelVertexOut surfaceLabelFlatVertex(SurfaceLabelVertexIn in [[stage_in]],
                                                    constant Camera& camera [[buffer(1)]],
                                                    constant float4x4& modelMatrix [[buffer(3)]],
                                                    constant SurfaceLabelDraw& draw [[buffer(4)]]) {
#define PROJECT(p) surfaceLabelFlatClip((p), camera, modelMatrix)
    SURFACE_LABEL_VERTEX_BODY(PROJECT)
#undef PROJECT
}

vertex SurfaceLabelVertexOut surfaceLabelSphereVertex(SurfaceLabelVertexIn in [[stage_in]],
                                                      constant SurfaceLabelDraw& draw [[buffer(4)]],
                                                      constant SurfaceLabelSphereTile& tile [[buffer(9)]],
                                                      constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
#define PROJECT(p) surfaceLabelSphereClip((p), tile, globeFrame)
    SURFACE_LABEL_VERTEX_BODY(PROJECT)
#undef PROJECT
}

vertex SurfaceLabelVertexOut surfaceLabelMorphVertex(SurfaceLabelVertexIn in [[stage_in]],
                                                     constant Camera& camera [[buffer(1)]],
                                                     constant SurfaceLabelDraw& draw [[buffer(4)]],
                                                     constant Globe& globe [[buffer(8)]],
                                                     constant SurfaceLabelSphereTile& tile [[buffer(9)]],
                                                     constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
#define PROJECT(p) surfaceLabelMorphClip((p), camera, globe, tile, globeFrame)
    SURFACE_LABEL_VERTEX_BODY(PROJECT)
#undef PROJECT
}

/// The glyph's distance fields in screen pixels. The pixel range comes from
/// the uv derivatives, so it follows the glyph's size on screen through the
/// perspective and the zoom (computeTextDistance in TextShader.metal).
fragment half4 surfaceLabelFragment(SurfaceLabelFragmentIn in [[stage_in]],
                                    texture2d<half> atlasTexture [[texture(0)]],
                                    constant SurfaceLabelDraw& draw [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    half4 atlasSample = atlasTexture.sample(textureSampler, in.uv);
    half3 msdf = atlasSample.rgb;
    float msdfDistance = float(max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b))) - 0.5;
    float sdfDistance = float(atlasSample.a) - 0.5;
    float2 textureSize = float2(atlasTexture.get_width(), atlasTexture.get_height());
    float2 unitRange = float2(kSurfaceLabelDistanceRange) / textureSize;
    float2 screenTextureSize = 1.0 / max(fwidth(in.uv), float2(1e-6));
    float screenPxRange = max(0.5 * dot(unitRange, screenTextureSize), 1.0);
    // Screen pixels per atlas texel.
    float pixelsPerTexel = screenPxRange / kSurfaceLabelDistanceRange;

    half coverage;
    half3 color;
    if (draw.haloPass > 0.5) {
        // The halo reaches past the glyph by its width, bounded by the
        // distance field's support.
        float haloPx = min(draw.haloAtlasTexels * pixelsPerTexel, max(0.5 * screenPxRange - 0.5, 0.0));
        if (haloPx <= 0.0) {
            discard_fragment();
        }
        coverage = half(smoothstep(-haloPx - 0.5, -haloPx + 0.5, sdfDistance * screenPxRange));
        color = half3(draw.strokeColor.rgb);
    } else {
        // The point labels' weight bias (textFragment), so a name reads
        // the same on the map as on the screen.
        const float boldBiasPx = 0.75;
        coverage = half(smoothstep(-0.5, 0.5, msdfDistance * screenPxRange + boldBiasPx));
        color = half3(draw.fillColor.rgb);
    }
    half alpha = coverage;
    if (alpha <= 0.0h) {
        discard_fragment();
    }
    return half4(color, alpha);
}
