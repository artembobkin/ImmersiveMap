// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

#include "../../Shaders/Shared/RenderUniforms.h"
#include "../../Shaders/Globe/GlobeVisibility.h"

struct TerrainVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float4 color [[attribute(2)]];
};

struct TerrainDrawUniform {
    float4x4 modelMatrix;
    uint renderMode;
    uint3 padding;
};

struct TerrainVertexOut {
    float4 position [[position]];
    float3 normal;
    float4 color;
};

vertex TerrainVertexOut terrainVertexShader(TerrainVertexIn vertexIn [[stage_in]],
                                            constant Camera& camera [[buffer(1)]],
                                            constant TerrainDrawUniform& terrain [[buffer(2)]],
                                            constant Globe& globe [[buffer(3)]]) {
    float4 worldPosition;
    float3 worldNormal;

    if (terrain.renderMode == 1) {
        float panLatitude = globeVisibilityPanLatitude(globe);
        float panLongitude = globeVisibilityPanLongitude(globe);
        float mapSize = globeVisibilityMapSize(globe, panLatitude);
        float panMercatorY = globeTransitionPanMercatorY(panLatitude);
        float4x4 rotation = globeVisibilityRotationMatrix(panLatitude, panLongitude);
        float height = length(vertexIn.position) - globe.radius;
        float3 sphereBasePosition = vertexIn.normal * globe.radius;
        float3 terrainOffset = vertexIn.normal * height;
        float3 sphereWorldPosition = (float4(sphereBasePosition, 1.0) * rotation
            - float4(0.0, 0.0, globe.radius, 0.0)).xyz
            + (float4(terrainOffset, 0.0) * rotation).xyz;

        float latitude = asin(clamp(vertexIn.normal.y, -1.0, 1.0));
        float longitude = atan2(vertexIn.normal.x, vertexIn.normal.z);
        float3 flatWorldPosition = globeFlatWorldPosition(latitude,
                                                          longitude,
                                                          globe,
                                                          mapSize,
                                                          panMercatorY)
            + float3(0.0, 0.0, height);
        worldPosition = float4(mix(sphereWorldPosition, flatWorldPosition, globe.transition), 1.0);
        worldNormal = normalize((float4(vertexIn.normal, 0.0) * rotation).xyz);
    } else {
        worldPosition = terrain.modelMatrix * float4(vertexIn.position, 1.0);
        worldNormal = normalize((terrain.modelMatrix * float4(vertexIn.normal, 0.0)).xyz);
    }

    TerrainVertexOut out;
    out.position = camera.matrix * worldPosition;
    out.normal = worldNormal;
    out.color = vertexIn.color;
    return out;
}

fragment float4 terrainFragmentShader(TerrainVertexOut in [[stage_in]]) {
    float3 lightDirection = normalize(float3(-0.35, 0.45, 0.82));
    float diffuse = saturate(dot(normalize(in.normal), lightDirection));
    float lighting = 0.58 + diffuse * 0.42;
    return float4(in.color.rgb * lighting, in.color.a);
}
