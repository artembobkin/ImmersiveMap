// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

// The sphere<->plane morph is evaluated ONCE per model anchor on the CPU
// (SceneModelAnchorMath) and arrives baked into the model matrix, so the model
// stays rigid through the morph and this shader is a plain rigid-body path.

struct SceneModelVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

struct SceneModelVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 uv;
};

struct SceneModelMaterial {
    float4 baseColor;
};

vertex SceneModelVertexOut sceneModelVertexShader(SceneModelVertexIn vertexIn [[stage_in]],
                                                  constant Camera& camera [[buffer(1)]],
                                                  constant float4x4& modelMatrix [[buffer(2)]],
                                                  constant float3x3& normalMatrix [[buffer(3)]]) {
    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);

    SceneModelVertexOut out;
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = normalize(normalMatrix * vertexIn.normal);
    // Model I/O content (USD, OBJ) authors texture coordinates with a
    // bottom-left origin; Metal samples top-left, so V flips here.
    out.uv = float2(vertexIn.uv.x, 1.0 - vertexIn.uv.y);
    return out;
}

// Depth-only vertex of the shadow map pass; the pipeline has no fragment
// function, the rasterizer writes bare depth.
vertex float4 sceneModelShadowVertexShader(SceneModelVertexIn vertexIn [[stage_in]],
                                           constant Camera& lightCamera [[buffer(1)]],
                                           constant float4x4& modelMatrix [[buffer(2)]]) {
    return lightCamera.matrix * (modelMatrix * float4(vertexIn.position, 1.0));
}

// No analytic lighting model, matching the building extrusion
// (TileExtruded.metal): the base color darkens only where the shadow map says
// the static sun is occluded: faces away from the sun are occluded by their
// own mesh in the map and come out shadowed like any cast shadow.
fragment float4 sceneModelFragmentShader(SceneModelVertexOut in [[stage_in]],
                                         constant SceneModelMaterial& material [[buffer(3)]],
                                         constant Shadow& shadow [[buffer(4)]],
                                         texture2d<float> baseColorTexture [[texture(0)]],
                                         depth2d<float> shadowMap [[texture(1)]],
                                         sampler baseColorSampler [[sampler(0)]]) {
    float4 base = baseColorTexture.sample(baseColorSampler, in.uv) * material.baseColor;
    float shadowFactor = sampleShadowFactor(shadow, shadowMap, in.worldPosition, in.worldNormal);
    return float4(base.rgb * shadowFactor, 1.0);
}
