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
// отбрасываются, иначе здания родителя перекрывали бы соседние точные тайлы.
static inline bool isOutsideLocalClip(float2 localPosition, float4 localClipBounds) {
    return localPosition.x < localClipBounds.x || localPosition.y < localClipBounds.y ||
           localPosition.x > localClipBounds.z || localPosition.y > localClipBounds.w;
}

static inline float3 extrudedLitColor(VertexOut in,
                                      constant Camera& camera,
                                      constant ExtrudedLight& light) {
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

    return ambient + diffuse + specular;
}

// Геометрия зданий всегда рисуется непрозрачно с обычным depth-тестом и MSAA:
// в solid-режиме - прямо в world-пасс, в translucent - в offscreen building
// image, который world-пасс затем накладывает на карту с общей альфой.
fragment float4 tileExtrudedFragmentShader(VertexOut in [[stage_in]],
                                           constant Camera& camera [[buffer(1)]],
                                           constant ExtrudedLight& light [[buffer(2)]],
                                           constant float4& localClipBounds [[buffer(4)]]) {
    if (isOutsideLocalClip(in.localPosition, localClipBounds)) {
        discard_fragment();
    }

    return float4(extrudedLitColor(in, camera, light), 1.0);
}

struct ExtrudedCompositeVertexOut {
    float4 position [[position]];
};

vertex ExtrudedCompositeVertexOut tileExtrudedCompositeVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    ExtrudedCompositeVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// Наложение building image на карту. Внутри изображения здания непрозрачны,
// но MSAA-resolve прозрачного фона оставляет в альфе покрытие силуэта, а цвет -
// премультиплицированным этим покрытием. Умножение на глобальную альфу и
// premultiplied-блендинг (one / oneMinusSourceAlpha) тонируют каждый пиксель
// карты ровно один раз - сколько бы поверхностей зданий ни перекрывалось.
fragment float4 tileExtrudedCompositeFragmentShader(ExtrudedCompositeVertexOut in [[stage_in]],
                                                    texture2d<float, access::read> buildingImage [[texture(0)]],
                                                    constant float& alpha [[buffer(0)]]) {
    float4 premultiplied = buildingImage.read(uint2(in.position.xy));
    return premultiplied * alpha;
}
