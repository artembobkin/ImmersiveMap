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

// localClipBounds: (minX, minY, maxX, maxY) in the source tile's local coordinates.
// A retained substitution draws the source's buildings in full - fragments outside
// the placeIn slot are discarded, otherwise the parent's buildings would cover
// neighboring exact tiles.
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

// Building geometry is always drawn opaque with a regular depth test and MSAA:
// in solid mode - directly into the world pass, in translucent - into the
// offscreen building image, which the world pass then composites over the map
// with a shared alpha.
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

// Compositing the building image over the map. Inside the image the buildings
// are opaque, but the MSAA resolve of the transparent background leaves the
// silhouette coverage in alpha, with the color premultiplied by that coverage.
// Multiplying by the global alpha and premultiplied blending
// (one / oneMinusSourceAlpha) tint every map pixel exactly once - no matter
// how many building surfaces overlap.
fragment float4 tileExtrudedCompositeFragmentShader(ExtrudedCompositeVertexOut in [[stage_in]],
                                                    texture2d<float, access::read> buildingImage [[texture(0)]],
                                                    constant float& alpha [[buffer(0)]]) {
    float4 premultiplied = buildingImage.read(uint2(in.position.xy));
    return premultiplied * alpha;
}
