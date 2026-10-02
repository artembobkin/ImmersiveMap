// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"

// The models of a model tile (ModelTileContents): every model of the tile
// is merged into one vertex buffer and one index buffer, in the tile's own
// space, with one texture array. A vertex says which layer of the array its
// texture is, so the whole tile draws in one call under one matrix, the
// tile's, with no bind between its models.
//
// Tile space is the flat map's: X east, Y north, Z up from the ground. The
// model matrix is a translation and a uniform scale, the one the map's own
// buildings of the same tile take, so the models lie on the flat map as the
// buildings do. They draw on the flat map only, as the buildings do: at the
// zooms that show them the map is flat.
//
// The ground cut is the scene models' (SceneModel.metal), in the same four
// draws: the footprint vertex function below raises and lowers the ground
// hole bit, and the clipped variant of the fragment function drops what
// lies below the surface outside the hole. The ground is the plane Z = 0.

// A model is drawn a little nearer in depth than it stands (depthBias, a
// share of its distance from the eye): every vertex moves toward the eye
// along its own ray, which leaves it where it was on the screen and takes
// only its depth forward. The map's own building a model stands in for,
// where a tile did not leave it out, reaches a little out of the model, and
// this is what puts the model over it. A building standing well in front
// of the model is nearer than the share takes the model, and still covers
// it. The shadow and the ground hole take a vertex where it stands.

// The clipped variant of the fragment function: below-ground fragments are
// dropped. Its own pipeline, so the plain variant keeps early depth.
constant bool kModelTileClipsBelowGround [[function_constant(0)]];

struct ModelTileVertexIn {
    float3 position [[attribute(0)]];
    // Signed normalized bytes in the tile.
    float3 normal [[attribute(1)]];
    // The layer of the tile's texture array.
    uint layer [[attribute(2)]];
    // Unsigned normalized shorts in the tile, V down: the origin is the top
    // left of the image, as Metal samples.
    float2 uv [[attribute(3)]];
};

struct ModelTileVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 uv;
    uint layer [[flat]];
};

vertex ModelTileVertexOut modelTileVertexShader(ModelTileVertexIn vertexIn [[stage_in]],
                                                constant Camera& camera [[buffer(1)]],
                                                constant float4x4& modelMatrix [[buffer(2)]],
                                                constant float& depthBias [[buffer(3)]]) {
    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);
    float3 drawnPosition = worldPosition.xyz + (camera.eye - worldPosition.xyz) * depthBias;

    ModelTileVertexOut out;
    out.position = camera.matrix * float4(drawnPosition, 1.0);
    out.worldPosition = worldPosition.xyz;
    // A translation and a uniform scale leave a direction as it is.
    out.worldNormal = normalize(vertexIn.normal);
    out.uv = vertexIn.uv;
    out.layer = vertexIn.layer;
    return out;
}

// The ground hole of a model that cuts into the ground: every vertex
// dropped onto the ground plane, so the mesh rasterises as its outline on
// the surface. No fragment function: the draw's stencil state raises or
// lowers the ground hole bit.
vertex float4 modelTileGroundFootprintVertexShader(ModelTileVertexIn vertexIn [[stage_in]],
                                                   constant Camera& camera [[buffer(1)]],
                                                   constant float4x4& modelMatrix [[buffer(2)]]) {
    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);
    return camera.matrix * float4(worldPosition.xy, 0.0, 1.0);
}

// Depth-only vertex of the shadow map pass: no fragment function, the
// rasterizer writes bare depth.
vertex float4 modelTileShadowVertexShader(ModelTileVertexIn vertexIn [[stage_in]],
                                          constant ShadowCasterMatrices& casters [[buffer(1)]],
                                          constant float4x4& modelMatrix [[buffer(2)]]) {
    return casters.lightProjectionView * (modelMatrix * float4(vertexIn.position, 1.0));
}

// No analytic lighting, matching the building extrusion and the scene
// models: the texture's color darkens only where the shadow map says the
// sun is occluded. The channel values are sampled raw, with no sRGB decode,
// as every model texture is.
fragment half4 modelTileFragmentShader(ModelTileVertexOut in [[stage_in]],
                                       constant Shadow& shadow [[buffer(4)]],
                                       texture2d_array<half> baseColorTextures [[texture(0)]],
                                       depth2d<float> shadowMap [[texture(1)]],
                                       sampler baseColorSampler [[sampler(0)]]) {
    if (kModelTileClipsBelowGround && in.worldPosition.z < 0.0) {
        discard_fragment();
    }
    half4 base = baseColorTextures.sample(baseColorSampler, in.uv, in.layer);
    half shadowFactor = half(sampleShadowFactor(shadow, shadowMap, in.worldPosition, in.worldNormal));
    return half4(base.rgb * shadowColorMultiplier(shadow, shadowFactor), 1.0h);
}
