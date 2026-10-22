// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Render/Shaders/Shared/RenderUniforms.h"
#include "../../Render/Shaders/Shared/GroundFog.h"

// The trees of the flat map: the tree model (TreeModelContents) drawn once
// per tree of a tile, each tree a TreeInstance of the tile's arena. A tree
// is turned about its trunk, scaled so the model's height spans the
// tree's height in tile units, and stood at its point, all in the tile's
// space, then taken into the world by the tile's matrix as the buildings
// are. The trees stand on the plane: they draw at the street zooms, where
// the ground relief is not.
//
// Their shadows are a soft disc each, on the ground under the crown: the
// crown's shadow as a sphere's would fall, its centre moved away from the
// sun by the crown's height and stretched along the sun's azimuth by the
// sun's lowness, multiplied into the ground after the roads with the
// darkening and the tint the shadow map gives every other shadow
// (shadowColorMultiplier). No map lookup, no caster pass.

// Mirror of TreeInstance.swift (vertex buffer 4), 16 bytes.
struct TreeInstance {
    float2 position;
    float height;
    uint packed;
};

// Mirror of TreeTileUniform in TreeDrawer.swift (vertex buffer 3).
struct TreeTile {
    float4x4 modelMatrix;
    /// What a unit of the model's height is in the model's own metres,
    /// times the tile's rise out of the ground.
    float heightScale;
    float3 padding;
};

// Mirror of TreeFrameUniform in TreeDrawer.swift (vertex and fragment
// buffer 7): the direction towards the light, unit length, the palette
// the model is coloured in (ImmersiveMapTreePalette), and the crown's
// radius and the height of its centre in the model's metres.
struct TreeFrame {
    float4 lightDirection;
    float4 crownColor;
    float4 crownShadeColor;
    float4 trunkColor;
    float4 crown;
};

// The model's vertex (TreeModelContents): `shading.x` is how far up the
// crown the point lies, 0 at the underside and 1 at the top (the trunk's
// from its foot to its top), `shading.y` is 1 on the trunk and 0 on the
// crown.
struct TreeVertexIn {
    float3 position [[attribute(0)]];
    float4 normal [[attribute(1)]];
    float4 shading [[attribute(2)]];
};

struct TreeVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    half3 worldNormal;
    half4 color;
};

static inline float2 turned(float2 point, float sinTurn, float cosTurn) {
    return float2(point.x * cosTurn - point.y * sinTurn,
                  point.x * sinTurn + point.y * cosTurn);
}

vertex TreeVertexOut treeVertexShader(TreeVertexIn vertexIn [[stage_in]],
                                      uint instanceID [[instance_id]],
                                      constant Camera& camera [[buffer(1)]],
                                      constant TreeTile& tile [[buffer(3)]],
                                      constant TreeInstance* instances [[buffer(4)]],
                                      constant TreeFrame& frame [[buffer(7)]]) {
    TreeInstance instance = instances[instanceID];
    float turn = float(instance.packed & 0xFFFFu) / 65535.0 * 2.0 * M_PI_F;
    float tint = float((instance.packed >> 16) & 0xFFu) / 255.0;
    float sinTurn = sin(turn);
    float cosTurn = cos(turn);
    float scale = instance.height * tile.heightScale;

    float3 local = vertexIn.position * scale;
    float3 placed = float3(turned(local.xy, sinTurn, cosTurn) + instance.position, local.z);
    float4 worldPosition = tile.modelMatrix * float4(placed, 1.0);

    float3 normal = vertexIn.normal.xyz;
    float3 turnedNormal = float3(turned(normal.xy, sinTurn, cosTurn), normal.z);
    float3x3 normalMatrix = float3x3(tile.modelMatrix[0].xyz, tile.modelMatrix[1].xyz, tile.modelMatrix[2].xyz);

    TreeVertexOut out;
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = half3(normalize(normalMatrix * turnedNormal));
    // The palette's colours by the point's part and depth in the crown.
    // The tint runs from a shade darker to a shade lighter, so a wood is
    // not one green.
    float3 crown = mix(frame.crownShadeColor.rgb, frame.crownColor.rgb, vertexIn.shading.x);
    float3 trunk = frame.trunkColor.rgb * (0.85 + 0.2 * vertexIn.shading.x);
    float3 color = vertexIn.shading.y > 0.5 ? trunk : crown;
    out.color = half4(half3(color * (0.86 + 0.28 * tint)), 1.0h);
    return out;
}

// A soft directional light over the palette's colours: most of the colour
// stands whatever the light, the sun side a little brighter, so the crown
// reads as a volume and its underside keeps its green. No shadow map: the
// trees are not in it, and shade the ground with their discs instead.
fragment half4 treeFragmentShader(TreeVertexOut in [[stage_in]],
                                  constant TreeFrame& frame [[buffer(7)]],
                                  constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]]) {
    half3 normal = normalize(in.worldNormal);
    half diffuse = max(dot(normal, half3(frame.lightDirection.xyz)), 0.0h);
    half shade = 0.68h + 0.26h * diffuse + 0.06h * saturate(normal.z);
    half4 color = half4(in.color.rgb * shade, 1.0h);
    color.rgb = applyGroundFog(color.rgb, in.worldPosition, groundFog);
    return color;
}

// The shadow disc: one quad per instance, two triangles from the vertex
// index, in the tile's space on the ground. The quad is the crown's
// shadow ellipse: the crown's radius across the sun's azimuth, and along
// it the radius over the sun's height (a sphere's shadow under parallel
// light), its centre where the crown's centre falls.
struct TreeShadowVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    /// The disc's own coordinates, the rim at length one.
    float2 disc;
};

constant float2 kTreeShadowCorners[6] = {
    float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)
};

vertex TreeShadowVertexOut treeShadowVertexShader(uint vertexID [[vertex_id]],
                                                  uint instanceID [[instance_id]],
                                                  constant Camera& camera [[buffer(1)]],
                                                  constant TreeTile& tile [[buffer(3)]],
                                                  constant TreeInstance* instances [[buffer(4)]],
                                                  constant TreeFrame& frame [[buffer(7)]]) {
    TreeInstance instance = instances[instanceID];
    float unitsPerMetre = instance.height * tile.heightScale;
    float radius = frame.crown.x * unitsPerMetre;
    float centreHeight = frame.crown.y * unitsPerMetre;

    float3 light = frame.lightDirection.xyz;
    // The sun never below a fifth of the sky, so the ellipse and the
    // offset stay in bounds whatever the settings say.
    float lightZ = max(light.z, 0.2);
    float2 horizontal = light.xy;
    float horizontalLength = length(horizontal);
    float2 along = horizontalLength > 1.0e-4 ? horizontal / horizontalLength : float2(1.0, 0.0);
    float2 across = float2(-along.y, along.x);

    float2 disc = kTreeShadowCorners[vertexID % 6u];
    float2 centre = instance.position - along * (horizontalLength / lightZ) * centreHeight;
    float2 point = centre + along * (disc.x * radius / lightZ) + across * (disc.y * radius);
    float4 worldPosition = tile.modelMatrix * float4(point, 0.0, 1.0);

    TreeShadowVertexOut out;
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.disc = disc;
    return out;
}

// The darkening of the ground under the disc: full inside, feathered to
// nothing at the rim, and gone into the fog as the ground is. The colour
// written is the multiplier the ground takes (the pipeline multiplies it
// in), the shadow map's own for a shadow of that depth.
fragment half4 treeShadowFragmentShader(TreeShadowVertexOut in [[stage_in]],
                                        constant Shadow& shadow [[buffer(5)]],
                                        constant GroundFog& groundFog [[buffer(kGroundFogBufferIndex)]]) {
    float distance = length(in.disc);
    float coverage = 1.0 - smoothstep(0.55, 1.0, distance);
    coverage *= 1.0 - groundFogAmount(in.worldPosition, groundFog);
    float3 multiplier = shadowColorMultiplier(shadow, 1.0 - coverage);
    return half4(half3(multiplier), 1.0h);
}
