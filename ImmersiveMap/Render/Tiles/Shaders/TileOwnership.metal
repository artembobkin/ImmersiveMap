// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

// The tile-ownership prepass: one full-extent quad per unique flat source,
// rasterized before anything else in the pass, writing only the
// tile-priority stencil (TileSourceStencilPriority). It gives the buildings
// a complete ownership map to test against before the ground has drawn:
// a substitute's buildings are rejected wherever a finer tile owns the
// pixel, streets and courtyards included. No fragment stage and no color
// or depth writes: the pipeline masks every attachment off.
struct TileOwnershipVertexOut {
    float4 position [[position]];
};

vertex TileOwnershipVertexOut tileOwnershipVertexShader(uint vertexID [[vertex_id]],
                                                        constant Camera& camera [[buffer(1)]],
                                                        constant float4x4& modelMatrix [[buffer(3)]]) {
    // A triangle-strip quad over the tile's local extent on the ground plane.
    const float2 corners[4] = {
        float2(0.0, 0.0), float2(4096.0, 0.0),
        float2(0.0, 4096.0), float2(4096.0, 4096.0)
    };
    TileOwnershipVertexOut out;
    out.position = camera.matrix * (modelMatrix * float4(corners[vertexID], 0.0, 1.0));
    return out;
}
