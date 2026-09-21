// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"

// A rasterized tile (TileRasterizer): the tile's picture, rendered once
// into a texture, drawn over the tile's extent on the ground plane as one
// quad. It stands in for the ground families it holds, so it takes a
// depth of the ground's rank band from the draw (an exact constant, like
// the coarse vector sources: the quad is as large as the tile and the
// near cut would move an interpolated band by thousands of steps) and the
// tile-priority stencil decides which source owns a pixel, exactly as for
// vector tiles. Lit by the ground shadow mask like a fill.
//
// The picture's alpha is its share of the pixel in the raster zone
// (RasterZone.swift): nothing nearer the camera than the zone's start, the
// whole pixel past its end, a smoothstep between, by the distance from the
// camera to the ground point. The measure is the pixel's, so the zone's
// edge crosses a tile anywhere and knows nothing of the grid.

// Same slot as Tile.metal's: the flat world pass reads the ground shadow
// mask, a pipeline without it binds nothing.
constant bool kTileRasterShadowMaskEnabled [[function_constant(0)]];

// One texel of the mask per this many drawable pixels; mirrors
// GroundShadowMaskPipeline.resolutionScale (and Tile.metal).
constant float kTileRasterShadowMaskScale = 0.4;

// Mirrors TileRasterZoneUniform (TileRasterDrawer.swift).
struct TileRasterZone {
    // xyz the camera in the render world, w the zone's start distance.
    float4 eyeAndStart;
    // x the zone's end distance, y the fragment's rank depth.
    float4 endAndRankDepth;
};

struct TileRasterVertexOut {
    float4 position [[position]];
    float2 uv;
    float3 worldPosition;
};

struct TileRasterFragmentOut {
    half4 color [[color(0)]];
    float depth [[depth(any)]];
};

vertex TileRasterVertexOut tileRasterVertexShader(uint vertexID [[vertex_id]],
                                                  constant Camera& camera [[buffer(1)]],
                                                  constant float4x4& modelMatrix [[buffer(3)]]) {
    // A triangle-strip quad over the tile's local extent, the ownership
    // quad's corners. The texture's first row is the tile's north edge
    // (the rasterizer's camera looks down with north up), and tile y grows
    // north here, so v runs against y.
    const float2 corners[4] = {
        float2(0.0, 0.0), float2(4096.0, 0.0),
        float2(0.0, 4096.0), float2(4096.0, 4096.0)
    };
    float2 corner = corners[vertexID];
    TileRasterVertexOut out;
    float4 worldPosition = modelMatrix * float4(corner, 0.0, 1.0);
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.uv = float2(corner.x / 4096.0, 1.0 - corner.y / 4096.0);
    return out;
}

fragment TileRasterFragmentOut tileRasterFragmentShader(TileRasterVertexOut in [[stage_in]],
                                                        constant Shadow& shadow [[buffer(3)]],
                                                        constant TileRasterZone& zone [[buffer(4)]],
                                                        texture2d<half> picture [[texture(0)]],
                                                        texture2d<half> groundShadowMask [[texture(1), function_constant(kTileRasterShadowMaskEnabled)]]) {
    // Trilinear with anisotropy: a far tile at a street tilt is minified
    // hundreds of times along the view and a few times across it.
    constexpr sampler pictureSampler(coord::normalized, filter::linear, mip_filter::linear,
                                     max_anisotropy(8), address::clamp_to_edge);
    half4 color = picture.sample(pictureSampler, in.uv);
    if (kTileRasterShadowMaskEnabled) {
        constexpr sampler maskSampler(coord::pixel, filter::linear, address::clamp_to_edge);
        half factor = shadow.strength > 0.0
            ? groundShadowMask.sample(maskSampler, in.position.xy * kTileRasterShadowMaskScale).r
            : half(1.0);
        color.rgb *= shadowColorMultiplier(shadow, factor);
    }
    TileRasterFragmentOut out;
    float distance = length(in.worldPosition - zone.eyeAndStart.xyz);
    float start = zone.eyeAndStart.w;
    float end = zone.endAndRankDepth.x;
    float share = end > start ? smoothstep(start, end, distance) : step(start, distance);
    out.color = half4(color.rgb, half(share));
    out.depth = zone.endAndRankDepth.y;
    return out;
}
