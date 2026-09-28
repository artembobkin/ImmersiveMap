// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"

// The sphere<->plane morph is evaluated ONCE per model anchor on the CPU
// (SceneModelAnchorMath) and arrives baked into the model matrix, so the model
// stays rigid through the morph and this shader is a plain rigid-body path.
//
// The ground cut (ImmersiveMapSceneModel.cutsIntoGround). The flat ground
// writes no real depth, only a rank band at the far plane (Tile.metal), so
// it hides nothing: a model sunk below the surface would show its
// underground part through the ground from every side. A model that cuts
// into the ground draws in four steps, all in the world pass
// (SceneModelDrawer): its own mesh flattened onto the ground plane raises
// the ground hole stencil bit over its outline (the footprint vertex
// function below), the mesh draws whole where the bit is raised, the mesh
// draws again where the bit is clear with every fragment below the surface
// dropped (kSceneModelClipsBelowGround), and the flattened mesh lowers the
// bit again. A fragment below the surface thus shows only in pixels whose
// view ray enters the ground inside the outline, which is the pit seen from
// above, and never where the ray meets intact ground beside the model. The
// ground itself needs no change: inside the outline the model's real depth
// beats the ground's band, so the ground fails its depth test there as it
// does under a building.

// The clipped variant of the fragment function: below-ground fragments are
// dropped. Its own pipeline, so the plain variant keeps early depth.
constant bool kSceneModelClipsBelowGround [[function_constant(0)]];

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
    // Height above the map surface under the anchor, in render units:
    // negative below the ground. Linear in the position, so it interpolates
    // exactly.
    float groundHeight;
};

struct SceneModelMaterial {
    float4 baseColor;
};

// Mirror of SceneModelGroundPlane in SceneModelAnchorMath.swift: the surface
// point under the anchor at altitude zero and the local up.
struct SceneModelGroundPlane {
    float3 surfacePosition;
    float3 up;
};

vertex SceneModelVertexOut sceneModelVertexShader(SceneModelVertexIn vertexIn [[stage_in]],
                                                  constant Camera& camera [[buffer(1)]],
                                                  constant float4x4& modelMatrix [[buffer(2)]],
                                                  constant float3x3& normalMatrix [[buffer(3)]],
                                                  constant SceneModelGroundPlane& ground [[buffer(4)]]) {
    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);

    SceneModelVertexOut out;
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = normalize(normalMatrix * vertexIn.normal);
    // Model I/O content (USD, OBJ) authors texture coordinates with a
    // bottom-left origin; Metal samples top-left, so V flips here.
    out.uv = float2(vertexIn.uv.x, 1.0 - vertexIn.uv.y);
    out.groundHeight = dot(worldPosition.xyz - ground.surfacePosition, ground.up);
    return out;
}

// The ground hole of a model that cuts into the ground: every vertex
// projected onto the ground plane along the up vector, so the mesh
// rasterises as its outline on the surface, seen by the frame's camera. The
// pipeline has no fragment function and writes no colour and no depth, the
// draw's stencil state raises or lowers the ground hole bit.
vertex float4 sceneModelGroundFootprintVertexShader(SceneModelVertexIn vertexIn [[stage_in]],
                                                    constant Camera& camera [[buffer(1)]],
                                                    constant float4x4& modelMatrix [[buffer(2)]],
                                                    constant SceneModelGroundPlane& ground [[buffer(4)]]) {
    float3 worldPosition = (modelMatrix * float4(vertexIn.position, 1.0)).xyz;
    float height = dot(worldPosition - ground.surfacePosition, ground.up);
    return camera.matrix * float4(worldPosition - ground.up * height, 1.0);
}

// Depth-only vertex of the shadow map pass; the pipeline has no fragment
// function, the rasterizer writes bare depth. One window means one draw per
// geometry into a plain 2D depth attachment.
vertex float4 sceneModelShadowVertexShader(SceneModelVertexIn vertexIn [[stage_in]],
                                           constant ShadowCasterMatrices& casters [[buffer(1)]],
                                           constant float4x4& modelMatrix [[buffer(2)]]) {
    return casters.lightProjectionView * (modelMatrix * float4(vertexIn.position, 1.0));
}

// No analytic lighting model, matching the building extrusion
// (TileExtruded.metal): the base color darkens only where the shadow map says
// the static sun is occluded: faces away from the sun are occluded by their
// own mesh in the map and come out shadowed like any cast shadow.
fragment half4 sceneModelFragmentShader(SceneModelVertexOut in [[stage_in]],
                                        constant SceneModelMaterial& material [[buffer(3)]],
                                        constant Shadow& shadow [[buffer(4)]],
                                        texture2d<half> baseColorTexture [[texture(0)]],
                                        depth2d<float> shadowMap [[texture(1)]],
                                        sampler baseColorSampler [[sampler(0)]]) {
    if (kSceneModelClipsBelowGround && in.groundHeight < 0.0) {
        discard_fragment();
    }
    half4 base = baseColorTexture.sample(baseColorSampler, in.uv) * half4(material.baseColor);
    half shadowFactor = half(sampleShadowFactor(shadow, shadowMap, in.worldPosition, in.worldNormal));
    return half4(base.rgb * shadowColorMultiplier(shadow, shadowFactor), 1.0h);
}
