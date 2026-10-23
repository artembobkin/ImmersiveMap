// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  Layers.metal
//  ImmersiveMap
//
//  The layers of the app's data (ImmersiveMapLayer): zones, lines and
//  points lying on the ground. Their geometry is stored as a map tile's is,
//  in the render units of a chunk tile (LayerMeshBuilder), and each vertex
//  is projected the ground's own way, on the surface the frame draws
//  (kLayerSurface), as the labels painted on the map are (SurfaceLabel.metal):
//
//  - the flat map, through the chunk's model matrix,
//  - the resting sphere, the unit earth direction through the composed
//    sphere matrix,
//  - the unfurl, the sphere-to-plane unroll with its cut.
//
//  A zone is its triangles. A line is a quad per segment, widened on
//  screen to the line's width in points, with a disc at every vertex for
//  its joins and its ends. A point is a disc with a ring round it, a quad
//  on screen. Everything is blended and never written to depth. What
//  stands in front of a layer (a building, a model, a tree) covers it by
//  the surface mask bit it raised in the stencil; the ground's depth hides
//  it only on a layer that asks (LayerPipeline.behindTerrainState), for
//  which its z is one constant depth in the ground's far-plane band, a
//  step behind the labels painted on the map (LayerDepth).
//

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"
#include "../../Render/Shaders/Shared/GroundFog.h"
#include "../../Globe/Shaders/GlobeTileProjection.h"
#include "../../Globe/Shaders/GlobeLight.h"

/// The surface the frame draws: 0 the flat map, 1 the resting sphere, 2
/// the unfurl. Mirrors LayerPipeline.Surface.
constant int kLayerSurface [[function_constant(0)]];
constant int kLayerSurfaceFlat = 0;
constant int kLayerSurfaceSphere = 1;

constant float kLayerTileExtent = 4096.0;
// The scale the projection applies to the z of everything real
// (RenderCamera.realDepthScale): the flat surface and the unfurl divide it
// out and apply the layer's own depth, as the labels painted on the map do.
constant float kLayerRealDepthScale = 1.0 - 1536.0 * 3.2e-6;
// A vertex nearer the camera than this in clip w is behind it.
constant float kLayerNearW = 1.0e-4;

/// Mirrors LayerFillVertex.swift.
struct LayerFillVertex {
    float2 position;
    uchar4 color;
};

/// Mirrors LayerLineVertex.swift.
struct LayerLineVertex {
    float2 start;
    float2 end;
    float2 corner;
    float widthPoints;
    uchar4 color;
};

/// Mirrors LayerPointInstance.swift.
struct LayerPointInstance {
    float2 position;
    float radiusPoints;
    float strokeWidthPoints;
    uchar4 color;
    uchar4 strokeColor;
};

/// Per-chunk draw state; mirrors LayerDrawUniform.swift.
struct LayerDraw {
    /// The chunk's flat model matrix (the flat surface).
    float4x4 modelMatrix;
    /// The chunk tile's world uv origin and size, and the world x the
    /// unfurl unwraps it around (the sphere and the unfurl).
    float2 uvOrigin;
    float uvScale;
    float referenceWorldX;
    float2 viewportSizePx;
    float pixelsPerPoint;
    /// The clip-space depth the layer lies at (LayerDepth).
    float depth;
};

/// A point of the surface in clip space, with what the fragment needs.
struct LayerClip {
    float4 position;
    float3 worldPosition;
    float3 sphereNormal;
    /// Negative where the surface hides the point: the far side of the
    /// sphere, the unroll's cut.
    float clipDistance;
};

static inline LayerClip layerProject(float2 local,
                                     constant Camera& camera,
                                     constant LayerDraw& draw,
                                     constant Globe& globe,
                                     constant GlobeFrameConstants& globeFrame) {
    LayerClip clip;
    if (kLayerSurface == kLayerSurfaceFlat) {
        float4 worldPosition = draw.modelMatrix * float4(local, 0.0, 1.0);
        clip.position = camera.matrix * worldPosition;
        clip.position.z *= draw.depth / kLayerRealDepthScale;
        clip.worldPosition = worldPosition.xyz;
        clip.sphereNormal = float3(0.0, 0.0, 1.0);
        clip.clipDistance = 1.0;
        return clip;
    }
    float2 localUv = float2(local.x, kLayerTileExtent - local.y) / kLayerTileExtent;
    float2 worldUv = draw.uvOrigin + localUv * draw.uvScale;
    float3 unitDirection = globeWorldUVUnitDirection(worldUv);
    float3 sphereWorldPosition = (globeFrame.sphereWorld * float4(unitDirection, 1.0)).xyz;
    clip.sphereNormal = (globeFrame.sphereWorld * float4(unitDirection, 0.0)).xyz;
    if (kLayerSurface == kLayerSurfaceSphere) {
        clip.position = globeFrame.sphereClip * float4(unitDirection, 1.0);
        clip.position.z = draw.depth * clip.position.w;
        clip.worldPosition = sphereWorldPosition;
        // The far side of the planet: a zone's triangles go to back-face
        // culling, but a line's and a point's quads face the camera, so
        // every vertex is cut where the sphere turns away from the eye.
        clip.clipDistance = dot(normalize(clip.sphereNormal), normalize(camera.eye - sphereWorldPosition));
        return clip;
    }
    float mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                                globeFrame.mapSize, globeFrame.panMercatorY,
                                                                draw.referenceWorldX);
    float3 worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                    globe.transition, globe.radius);
    clip.position = camera.matrix * float4(worldPosition, 1.0);
    clip.position.z *= draw.depth / kLayerRealDepthScale;
    clip.worldPosition = worldPosition;
    clip.clipDistance = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                                globe.transition, globe.radius);
    return clip;
}

/// The colour as the ground under it is lit: the globe's sun on the
/// sphere and through the unfurl, the ground fog on the plane.
static inline half4 layerShade(half4 color, float3 worldPosition, float3 sphereNormal,
                               constant GlobeLight& globeLight, constant GroundFog& groundFog) {
    if (kLayerSurface != kLayerSurfaceFlat) {
        color.rgb = globeLitColor(color.rgb, sphereNormal, globeLight);
    }
    color.rgb = applyGroundFog(color.rgb, worldPosition, groundFog);
    return color;
}

// MARK: - Zones

struct LayerFillOut {
    float4 position [[position]];
    float clipDistance [[clip_distance]] [1];
    float3 worldPosition;
    float3 sphereNormal;
    half4 color;
};

struct LayerFillIn {
    float4 position [[position]];
    float3 worldPosition;
    float3 sphereNormal;
    half4 color;
};

vertex LayerFillOut layerFillVertex(uint vertexID [[vertex_id]],
                                    constant LayerFillVertex* vertices [[buffer(0)]],
                                    constant Camera& camera [[buffer(1)]],
                                    constant LayerDraw& draw [[buffer(2)]],
                                    constant Globe& globe [[buffer(8)]],
                                    constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    LayerFillVertex vertexIn = vertices[vertexID];
    LayerClip clip = layerProject(vertexIn.position, camera, draw, globe, globeFrame);
    LayerFillOut out;
    out.position = clip.position;
    // The fill keeps the sphere's back-face culling for the far side; the
    // cut is the unfurl's alone.
    out.clipDistance[0] = kLayerSurface == kLayerSurfaceSphere ? 1.0 : clip.clipDistance;
    out.worldPosition = clip.worldPosition;
    out.sphereNormal = clip.sphereNormal;
    out.color = half4(float4(vertexIn.color) / 255.0);
    return out;
}

fragment half4 layerFillFragment(LayerFillIn in [[stage_in]],
                                 constant GlobeLight& globeLight [[buffer(kGlobeLightBufferIndex)]],
                                 constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]]) {
    return layerShade(in.color, in.worldPosition, in.sphereNormal, globeLight, groundFog);
}

// MARK: - Lines

struct LayerLineOut {
    float4 position [[position]];
    float clipDistance [[clip_distance]] [1];
    float3 worldPosition;
    float3 sphereNormal;
    half4 color;
    /// The signed distance from the centreline across the quad, in
    /// pixels, and the line's half width in pixels.
    float edgePx;
    float halfWidthPx [[flat]];
};

struct LayerLineIn {
    float4 position [[position]];
    float3 worldPosition;
    float3 sphereNormal;
    half4 color;
    float edgePx;
    float halfWidthPx [[flat]];
};

vertex LayerLineOut layerLineVertex(uint vertexID [[vertex_id]],
                                    constant LayerLineVertex* vertices [[buffer(0)]],
                                    constant Camera& camera [[buffer(1)]],
                                    constant LayerDraw& draw [[buffer(2)]],
                                    constant Globe& globe [[buffer(8)]],
                                    constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    LayerLineVertex vertexIn = vertices[vertexID];
    LayerClip start = layerProject(vertexIn.start, camera, draw, globe, globeFrame);
    LayerClip end = layerProject(vertexIn.end, camera, draw, globe, globeFrame);
    // An end behind the camera is pulled to just before it along the
    // segment, so the quad's direction on screen stays the segment's.
    float4 startClip = start.position;
    float4 endClip = end.position;
    if (startClip.w < kLayerNearW && endClip.w > kLayerNearW) {
        startClip = mix(startClip, endClip, (kLayerNearW - startClip.w) / (endClip.w - startClip.w));
    } else if (endClip.w < kLayerNearW && startClip.w > kLayerNearW) {
        endClip = mix(endClip, startClip, (kLayerNearW - endClip.w) / (startClip.w - endClip.w));
    }
    float2 halfViewport = draw.viewportSizePx * 0.5;
    float2 startScreen = startClip.xy / max(startClip.w, kLayerNearW) * halfViewport;
    float2 endScreen = endClip.xy / max(endClip.w, kLayerNearW) * halfViewport;
    float2 direction = endScreen - startScreen;
    float length2 = dot(direction, direction);
    direction = length2 > 1.0e-8 ? direction * rsqrt(length2) : float2(1.0, 0.0);
    float2 normal = float2(-direction.y, direction.x);

    float halfWidthPx = vertexIn.widthPoints * draw.pixelsPerPoint * 0.5;
    // A pixel of margin for the edge's antialiasing.
    float extentPx = halfWidthPx + 1.0;
    bool atEnd = vertexIn.corner.x > 0.5;
    LayerClip at = atEnd ? end : start;
    float4 position = atEnd ? endClip : startClip;
    position.xy += normal * (vertexIn.corner.y * extentPx) / halfViewport * position.w;

    LayerLineOut out;
    out.position = position;
    out.clipDistance[0] = (startClip.w < kLayerNearW && endClip.w < kLayerNearW) ? -1.0 : at.clipDistance;
    out.worldPosition = at.worldPosition;
    out.sphereNormal = at.sphereNormal;
    out.color = half4(float4(vertexIn.color) / 255.0);
    out.edgePx = vertexIn.corner.y * extentPx;
    out.halfWidthPx = halfWidthPx;
    return out;
}

fragment half4 layerLineFragment(LayerLineIn in [[stage_in]],
                                 constant GlobeLight& globeLight [[buffer(kGlobeLightBufferIndex)]],
                                 constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]]) {
    half4 color = in.color;
    color.a *= half(saturate(in.halfWidthPx + 0.5 - abs(in.edgePx)));
    return layerShade(color, in.worldPosition, in.sphereNormal, globeLight, groundFog);
}

// MARK: - Points and joins

struct LayerPointOut {
    float4 position [[position]];
    float clipDistance [[clip_distance]] [1];
    float3 worldPosition;
    float3 sphereNormal;
    half4 color [[flat]];
    half4 strokeColor [[flat]];
    /// The fragment's offset from the centre, in pixels.
    float2 offsetPx;
    float radiusPx [[flat]];
    float strokeWidthPx [[flat]];
};

struct LayerPointIn {
    float4 position [[position]];
    float3 worldPosition;
    float3 sphereNormal;
    half4 color [[flat]];
    half4 strokeColor [[flat]];
    float2 offsetPx;
    float radiusPx [[flat]];
    float strokeWidthPx [[flat]];
};

constant float2 kLayerPointCorners[6] = {
    float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
    float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
};

vertex LayerPointOut layerPointVertex(uint vertexID [[vertex_id]],
                                      uint instanceID [[instance_id]],
                                      constant LayerPointInstance* instances [[buffer(0)]],
                                      constant Camera& camera [[buffer(1)]],
                                      constant LayerDraw& draw [[buffer(2)]],
                                      constant Globe& globe [[buffer(8)]],
                                      constant GlobeFrameConstants& globeFrame [[buffer(10)]]) {
    LayerPointInstance instance = instances[instanceID];
    LayerClip centre = layerProject(instance.position, camera, draw, globe, globeFrame);
    float radiusPx = instance.radiusPoints * draw.pixelsPerPoint;
    float strokeWidthPx = instance.strokeWidthPoints * draw.pixelsPerPoint;
    float extentPx = radiusPx + strokeWidthPx + 1.0;
    float2 corner = kLayerPointCorners[vertexID % 6u];

    LayerPointOut out;
    out.position = centre.position;
    out.position.xy += corner * extentPx / (draw.viewportSizePx * 0.5) * out.position.w;
    out.clipDistance[0] = centre.position.w < kLayerNearW ? -1.0 : centre.clipDistance;
    out.worldPosition = centre.worldPosition;
    out.sphereNormal = centre.sphereNormal;
    out.color = half4(float4(instance.color) / 255.0);
    out.strokeColor = half4(float4(instance.strokeColor) / 255.0);
    out.offsetPx = corner * extentPx;
    out.radiusPx = radiusPx;
    out.strokeWidthPx = strokeWidthPx;
    return out;
}

fragment half4 layerPointFragment(LayerPointIn in [[stage_in]],
                                  constant GlobeLight& globeLight [[buffer(kGlobeLightBufferIndex)]],
                                  constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]]) {
    float distance = length(in.offsetPx);
    // The disc, then the ring outside it, each with a pixel of
    // antialiasing at its edge.
    half inside = half(saturate(in.radiusPx + 0.5 - distance));
    half covered = half(saturate(in.radiusPx + in.strokeWidthPx + 0.5 - distance));
    if (covered <= 0.0h) {
        discard_fragment();
    }
    half4 color = in.strokeWidthPx > 0.0 ? mix(in.strokeColor, in.color, inside) : in.color;
    color.a *= covered;
    return layerShade(color, in.worldPosition, in.sphereNormal, globeLight, groundFog);
}
