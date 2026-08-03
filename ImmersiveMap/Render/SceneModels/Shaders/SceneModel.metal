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

struct SceneModelLight {
    float4 direction;
    float4 color;
    float4 intensities; // x: ambient, y: diffuse, z: specular, w: shininess
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

// Phong identical to the building extrusion (TileExtruded.metal) so models and
// buildings share one light: ambient + lambert + specular gated on diffuse.
fragment float4 sceneModelFragmentShader(SceneModelVertexOut in [[stage_in]],
                                         constant Camera& camera [[buffer(1)]],
                                         constant SceneModelLight& light [[buffer(2)]],
                                         constant SceneModelMaterial& material [[buffer(3)]],
                                         texture2d<float> baseColorTexture [[texture(0)]],
                                         sampler baseColorSampler [[sampler(0)]]) {
    float4 base = baseColorTexture.sample(baseColorSampler, in.uv) * material.baseColor;
    float3 normal = normalize(in.worldNormal);
    float3 lightDirection = normalize(light.direction.xyz);
    float3 viewDirection = normalize(camera.eye - in.worldPosition);

    float diffuseFactor = max(dot(normal, lightDirection), 0.0);
    float3 reflectDirection = reflect(-lightDirection, normal);
    float specularFactor = diffuseFactor > 0.0
        ? pow(max(dot(viewDirection, reflectDirection), 0.0), light.intensities.w)
        : 0.0;

    float3 lightColor = light.color.rgb;
    float3 ambient = base.rgb * light.intensities.x * lightColor;
    float3 diffuse = base.rgb * light.intensities.y * diffuseFactor * lightColor;
    float3 specular = lightColor * light.intensities.z * specularFactor;

    return float4(ambient + diffuse + specular, 1.0);
}
