// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    unsigned char styleIndex [[attribute(2)]];
    uint surfaceID [[attribute(3)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 localPosition;
    float4 color;
    uint surfaceID [[flat]];
    float pointSize [[point_size]];
};

struct Style {
    float4 color;
};

struct ExtrudedLight {
    float4 direction;
    float4 color;
    float4 intensities; // x: ambient, y: diffuse, z: specular, w: shininess
};

struct ExtrudedMaterial {
    float alpha;
    float3 padding;
};

vertex VertexOut tileExtrudedVertexShader(VertexIn vertexIn [[stage_in]],
                                          constant Camera& camera [[buffer(1)]],
                                          constant Style* styles [[buffer(2)]],
                                          constant float4x4& modelMatrix [[buffer(3)]]) {
    Style style = styles[vertexIn.styleIndex];
    float4x4 matrix = camera.matrix;

    float4 worldPosition = modelMatrix * float4(vertexIn.position, 1.0);
    float4 clipPosition = matrix * worldPosition;
    float3x3 normalMatrix = float3x3(modelMatrix[0].xyz, modelMatrix[1].xyz, modelMatrix[2].xyz);
    float3 worldNormal = normalize(normalMatrix * vertexIn.normal);

    VertexOut out;
    out.position = clipPosition;
    out.pointSize = 5.0;
    out.color = style.color;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = worldNormal;
    out.localPosition = vertexIn.position.xy;
    out.surfaceID = vertexIn.surfaceID;
    return out;
}

// localClipBounds: (minX, minY, maxX, maxY) в локальных координатах source-тайла.
// Retained-подмена рисует здания source целиком - фрагменты вне слота placeIn
// отбрасываются и в winner-препассе, и в цветовом пассе, иначе здания родителя
// перекрывали бы соседние точные тайлы (и их winner ID).
static inline bool isOutsideLocalClip(float2 localPosition, float4 localClipBounds) {
    return localPosition.x < localClipBounds.x || localPosition.y < localClipBounds.y ||
           localPosition.x > localClipBounds.z || localPosition.y > localClipBounds.w;
}

fragment uint tileExtrudedWinnerFragmentShader(VertexOut in [[stage_in]],
                                               constant float4& localClipBounds [[buffer(4)]]) {
    if (isOutsideLocalClip(in.localPosition, localClipBounds)) {
        discard_fragment();
    }
    return in.surfaceID;
}

fragment float4 tileExtrudedFragmentShader(VertexOut in [[stage_in]],
                                           texture2d<uint, access::read> winnerTexture [[texture(0)]],
                                           constant Camera& camera [[buffer(1)]],
                                           constant ExtrudedLight& light [[buffer(2)]],
                                           constant ExtrudedMaterial& material [[buffer(3)]],
                                           constant float4& localClipBounds [[buffer(4)]]) {
    if (isOutsideLocalClip(in.localPosition, localClipBounds)) {
        discard_fragment();
    }
    uint storedWinnerID = winnerTexture.read(uint2(in.position.xy)).r;
    if (storedWinnerID == 0 || storedWinnerID != in.surfaceID) {
        discard_fragment();
    }

    float3 normal = normalize(in.worldNormal);
    float3 lightDir = normalize(light.direction.xyz);
    float3 viewDir = normalize(camera.eye - in.worldPosition);

    float diffuseFactor = max(dot(normal, lightDir), 0.0);
    float3 reflectDir = reflect(-lightDir, normal);
    float specularFactor = diffuseFactor > 0.0
        ? pow(max(dot(viewDir, reflectDir), 0.0), light.intensities.w)
        : 0.0;

    float3 lightColor = light.color.rgb;
    float3 baseColor = in.color.rgb;

    float3 ambient = baseColor * light.intensities.x * lightColor;
    float3 diffuse = baseColor * light.intensities.y * diffuseFactor * lightColor;
    float3 specular = lightColor * light.intensities.z * specularFactor;

    float3 finalColor = ambient + diffuse + specular;
    return float4(finalColor, in.color.a * material.alpha);
}
