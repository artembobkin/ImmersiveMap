// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"

// A rasterized tile (TileRasterizer): the tile's picture, rendered once
// into a texture, drawn over the tile's extent on the ground plane as one
// quad. It stands in for every ground layer of the tile at once, so it
// takes the ground's rank band as the fragment's depth (an exact constant,
// like the coarse vector sources: the quad is as large as the tile and the
// near cut would move an interpolated band by thousands of steps) and the
// tile-priority stencil decides which source owns a pixel, exactly as for
// vector tiles. Lit by the ground shadow mask like a fill.

// Same slot as Tile.metal's: the flat world pass reads the ground shadow
// mask, a pipeline without it binds nothing.
constant bool kTileRasterShadowMaskEnabled [[function_constant(0)]];

// One texel of the mask per this many drawable pixels; mirrors
// GroundShadowMaskPipeline.resolutionScale (and Tile.metal).
constant float kTileRasterShadowMaskScale = 0.4;

// The ground's rank band for the whole tile: the opaque fills' first rank
// (Tile.metal, kFlatTileLayerDepthStep), so the raster sits where the
// tile's base fill would.
constant float kTileRasterRankDepth = 1.0 - 4e-7;

struct TileRasterVertexOut {
    float4 position [[position]];
    float2 uv;
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
    out.position = camera.matrix * (modelMatrix * float4(corner, 0.0, 1.0));
    out.uv = float2(corner.x / 4096.0, 1.0 - corner.y / 4096.0);
    return out;
}

fragment TileRasterFragmentOut tileRasterFragmentShader(TileRasterVertexOut in [[stage_in]],
                                                        constant Shadow& shadow [[buffer(3)]],
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
    out.color = half4(color.rgb, 1.0h);
    out.depth = kTileRasterRankDepth;
    return out;
}
