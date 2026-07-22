// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "GlobeTransitionProjection.h"
#include "../Shared/AtlasSampling.h"

// Add necessary structures for transformation and rendering
struct VertexIn {
    float2 uv [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float2 texCoord;
    float uvSize;
    float posU;
    float posV;
    float lastPos;
    float halfTexel;  // For inset clamping and discard relaxation
    float3 normal;
    float3 worldPos;
    float transition;
    float3 earthNormal;
};

struct CapVertexIn {
    float2 latLon [[attribute(0)]];
};

struct CapVertexOut {
    float4 position [[position]];
    float capAlpha;
    float absLatitude;
    float latitude;
    float longitude;
    float3 normal;
    float3 worldPos;
    float3 earthNormal;
};

struct CapParams {
    float4 edgeColor;
    float4 fillColor;
    float blendStartAbsLatitude;
    float blendEndAbsLatitude;
    float4 sampleOptions;
};

struct Tile {
    int position;
    int textureSize;
    int cellSize;
    int3 tile;
    int3 sourceTile;
};


vertex VertexOut globeVertexShader(VertexIn vertexIn [[stage_in]],
                                   constant Camera& camera [[buffer(1)]],
                                   constant Globe& globe [[buffer(2)]],
                                   constant Tile& tileData [[buffer(3)]]) {
    
    float2 tileLocalUV = vertexIn.uv;
    float vertexUvX = vertexIn.uv.x; // goes 0 to 1
    float vertexUvY = vertexIn.uv.y; // goes 0 to 1
    
    int tileX = tileData.tile.x;
    int tileY = tileData.tile.y;
    int tileZ = tileData.tile.z;
    
    float zPow = pow(2.0, tileZ);
    float size = 1.0 / zPow;
    
    vertexUvX = vertexUvX / zPow + size * tileX;
    
    float latNorth = atan(sinh(M_PI_F * (1.0 - 2.0 * tileY / zPow)));
    float latSouth = atan(sinh(M_PI_F * (1.0 - 2.0 * (tileY + 1) / zPow)));
    float vNorth = 1.0 - (latNorth + M_PI_2_F) / M_PI_F;
    float vSouth = 1.0 - (latSouth + M_PI_2_F) / M_PI_F;
    float vSize = abs(vSouth - vNorth);
    vertexUvY = vNorth + vertexUvY * vSize;
    
    
    float transition = globe.transition; // from globe view to flat view
    
    
    // Map coordinates
    float latitude = globeTransitionPanLatitude(globe);
    float longitude = globeTransitionPanLongitude(globe);
    
    float globeRadius = globe.radius;
    
    
    float textureSize = tileData.textureSize;
    float cellSize = tileData.cellSize;
    int count = textureSize / cellSize;
    
    
    int posU = tileData.position % count;
    int posV = tileData.position / count;
    int lastPos = count - 1;
    
    float4x4 matrix = camera.matrix;
    
    float mapSize = globeTransitionMapSize(globe, latitude);
    
    float phi = -M_PI_F * vertexUvY;
    float theta = 2 * M_PI_F * vertexUvX;
     
    float x = globeRadius * sin(phi) * sin(theta);
    float y = globeRadius * cos(phi);
    float z = globeRadius * sin(phi) * cos(theta);
    float3 spherePosition = float3(x, y, z);
    
    
    // Rotate the planet
    float cx = cos(-latitude);
    float sx = sin(-latitude);
    float cy = cos(-longitude);
    float sy = sin(-longitude);

    float4x4 rotation = float4x4(
        float4(cy,        0,         -sy,       0),
        float4(sy * sx,   cx,        cy * sx,   0),
        float4(sy * cx,  -sx,        cy * cx,   0),
        float4(0,         0,          0,        1)
    );


    // Convert globePanY (-1..1) to a Mercator-aligned vertical pan so the flat map
    float panY_merc_norm = globeTransitionPanMercatorY(latitude);
    
    // `vertexUvY` grows top-to-bottom, so this intermediate latitude is sign-inverted
    // relative to geographic latitude and needs the extra negation below.
    float lat_v = M_PI_F * vertexUvY - M_PI_2_F;      // [-pi/2..pi/2]
    float flatMercatorY = -getYMercNorm(lat_v);       // geographic-Mercator sign in flat world space
    float2 flatWorldPosition = globeTransitionFlatWorldPosition(vertexUvX,
                                                                flatMercatorY,
                                                                globe,
                                                                mapSize,
                                                                panY_merc_norm);
    
    float4x4 translationM = translationMatrix(float3(0, 0, -globeRadius));
    float4 spherePositionTranslated = float4(spherePosition, 1.0) * rotation * translationM;
    float4 flatPosition = float4(flatWorldPosition, 0, 1.0);
    float3 rotatedSphereDirection = normalize((float4(spherePosition, 0.0) * rotation).xyz);
    float localTransition = globeTransitionLocalPhase(transition, rotatedSphereDirection.z);
    float4 position = mix(spherePositionTranslated, flatPosition, localTransition);
    float4 clip = matrix * position;
    // Compute texture coordinates for blending
    float u = 1.0 - vertexUvX;
    
    int tilesCount = int(zPow);
    int lastTile = tilesCount - 1;
    float sphereV = (-flatMercatorY - 1.0) / -2.0;
    float v = sphereV;
    float t_u = ((1.0 - u) * zPow - tileX + posU) / count;
    float t_v = (1.0 - v * zPow + (lastTile - tileY) + float(lastPos - posV)) / count;
    
    VertexOut out;
    // Keep clip-space position; GPU performs the perspective divide.
    out.position = clip;
    out.pointSize = 5.0;
    out.texCoord = float2(t_u, t_v);
    out.uvSize = 1.0 / count;
    out.posU = posU;
    out.posV = posV;
    out.lastPos = lastPos;
    out.halfTexel = 0.5 / textureSize;
    out.normal = rotatedSphereDirection;
    // Морфированная позиция, а не сферическая: по ней считается туман, и его
    // дистанции обязаны совпадать с плоским путём (на сфере хорды короче, и
    // туман был жиже, «дотягиваясь» скачком на свапе). При t = 0 значения
    // бит-в-бит равны сферическим, так что свечение лимба не меняется.
    out.worldPos = position.xyz;
    out.transition = transition;
    out.earthNormal = normalize(spherePosition);
    return out;
}

struct GlobeCapAtlasSample {
    float2 uv;
    bool isValid;
};

static float globeCapWrapUnit(float value) {
    return value - floor(value);
}

static GlobeCapAtlasSample globeCapAtlasSampleUV(float latitude,
                                                 float longitude,
                                                 constant Tile& tileData) {
    float textureSize = float(tileData.textureSize);
    float cellSize = float(tileData.cellSize);
    if (textureSize <= 0.0 || cellSize <= 0.0) {
        return GlobeCapAtlasSample{float2(0.0), false};
    }

    int count = int(textureSize / cellSize);
    if (count <= 0) {
        return GlobeCapAtlasSample{float2(0.0), false};
    }

    int tileX = tileData.tile.x;
    int tileY = tileData.tile.y;
    int tileZ = tileData.tile.z;
    float zPow = exp2(float(tileZ));
    float normalizedWorldX = globeCapWrapUnit(longitude / (2.0 * M_PI_F));
    float mercatorY = getYMercNorm(latitude);

    // Only the longitude (X) axis decides which edge-row tile owns this cap wedge.
    // The draw loop already guarantees this tile is the matching pole row
    // (tile.y == 0 for the north cap, lastTileY for the south cap), and every
    // fragment samples the fixed boundary latitude +-maxLatitude, so the vertical
    // atlas coordinate sits exactly on the tile knife-edge (localY == 0 or 1).
    // Testing that against a tight epsilon spuriously fails under GPU float /
    // fast-math rounding and leaves the static fallback color showing at the pole.
    // The returned V is clamped to this tile's edge texel below, so no Y test is
    // needed here.
    float localX = normalizedWorldX * zPow - float(tileX);
    float epsilon = 0.00001;
    if (localX < -epsilon || localX > 1.0 + epsilon) {
        return GlobeCapAtlasSample{float2(0.0), false};
    }

    int position = tileData.position;
    int posU = position % count;
    int posV = position / count;
    int lastPos = count - 1;
    int lastTile = int(zPow) - 1;
    float textureV = (mercatorY + 1.0) * 0.5;
    float u = (normalizedWorldX * zPow - float(tileX) + float(posU)) / float(count);
    float v = (1.0 - textureV * zPow + float(lastTile - tileY) + float(lastPos - posV)) / float(count);

    float uvSize = 1.0 / float(count);
    float halfTexel = 0.5 / textureSize;
    float uMin = float(posU) * uvSize;
    float uMax = uMin + uvSize;
    float vMin = float(lastPos - posV) * uvSize;
    float vMax = 1.0 - float(posV) * uvSize;

    return GlobeCapAtlasSample{
        float2(clamp(u, uMin + halfTexel, uMax - halfTexel),
               clamp(v, vMin + halfTexel, vMax - halfTexel)),
        true
    };
}

fragment float4 globeFragmentShader(VertexOut in [[stage_in]],
                                    texture2d<float> texture [[texture(0)]],
                                    constant Camera& camera [[buffer(1)]],
                                    constant EarthScene& earthScene [[buffer(2)]],
                                    constant Tile& tileData [[buffer(3)]],
                                    constant HorizonFog& horizonFog [[buffer(4)]]) {
    constexpr sampler textureSampler(filter::linear, mip_filter::linear, mag_filter::linear);
    
//    return float4(1.0, 0, 0, 1);
    
    AtlasTileBounds bounds = atlasTileBounds(in.posU, in.posV, in.lastPos, in.uvSize);
    AtlasSampleCoords coords = atlasSampleCoords(in.texCoord, bounds, in.halfTexel);
    if (coords.outsideCoverage) {
        discard_fragment();
    }

    float4 color = texture.sample(textureSampler, coords.uv, level(coords.lod));
    if (earthScene.isEnabled != 0) {
        float sunDot = dot(normalize(in.earthNormal), normalize(earthScene.sunDirection));
        float dayFactor = smoothstep(-earthScene.terminatorFadeWidth,
                                     earthScene.terminatorFadeWidth,
                                     sunDot);
        float dayBrightness = mix(earthScene.daySideMinimumBrightness, 1.0, dayFactor);
        float surfaceBrightness = mix(earthScene.nightSideBrightness, dayBrightness, dayFactor);
        surfaceBrightness = mix(surfaceBrightness, 1.0, in.transition);
        surfaceBrightness = mix(surfaceBrightness, 1.0, earthScene.sunShadowFade);
        color.rgb *= surfaceBrightness;
    }

    float3 viewDir = normalize(camera.eye - in.worldPos);
    float rim = pow(max(0.0, 1.0 - dot(in.normal, viewDir)), 2.35);
    float outerGlow = pow(max(0.0, 1.0 - dot(in.normal, viewDir)), 5.2);
    float glowStrength = rim * 0.38 * (1.0 - in.transition);
    float3 innerGlowColor = float3(0.28, 0.54, 1.0) * glowStrength;
    float3 outerGlowColor = float3(0.08, 0.22, 0.72) * outerGlow * 0.22 * (1.0 - in.transition);
    color.rgb += innerGlowColor + outerGlowColor;
    // Дымка гейтится фазой перехода (strength = transition): чистый глобус в
    // космосе остаётся без тумана, а к моменту смены поверхностей морф и
    // плоскость затуманены одинаково - шов линии горизонта скрыт.
    color.rgb = applyHorizonFog(color.rgb, horizonFog, in.worldPos);
    return color;
}

vertex CapVertexOut globeCapVertexShader(CapVertexIn vertexIn [[stage_in]],
                                         constant Camera& camera [[buffer(1)]],
                                         constant Globe& globe [[buffer(2)]]) {
    float lat = vertexIn.latLon.x;
    float lon = vertexIn.latLon.y;
    
    float globeRadius = globe.radius;
    // Cap geometry stores geographic latitude directly. The globe tile path uses
    // phi = geographicLatitude - pi/2 after Mercator->sphere conversion, so caps
    // must use the same convention or north/south hemispheres get swapped.
    float phi = lat - M_PI_2_F;
    float theta = lon;
    
    float x = globeRadius * sin(phi) * sin(theta);
    float y = globeRadius * cos(phi);
    float z = globeRadius * sin(phi) * cos(theta);
    float3 spherePosition = float3(x, y, z);
    
    float maxLatitude = 2.0 * atan(exp(M_PI_F)) - M_PI_2_F;
    float latitude = globe.panY * maxLatitude;
    float longitude = globe.panX * M_PI_F;
    
    float cx = cos(-latitude);
    float sx = sin(-latitude);
    float cy = cos(-longitude);
    float sy = sin(-longitude);
    
    float4x4 rotation = float4x4(
        float4(cy,        0,         -sy,       0),
        float4(sy * sx,   cx,        cy * sx,   0),
        float4(sy * cx,  -sx,        cy * cx,   0),
        float4(0,         0,          0,        1)
    );
    
    float4x4 translationM = translationMatrix(float3(0, 0, -globeRadius));
    float4 spherePositionTranslated = float4(spherePosition, 1.0) * rotation * translationM;
    float4 clip = camera.matrix * spherePositionTranslated;
    
    // Крышка не морфится в плоскость: при развороте она расходится с тайловой
    // поверхностью, поэтому гаснет в первой трети перехода, пока расхождение
    // ещё не заметно.
    const float capFadeEndTransition = 0.35;
    float transitionFade = smoothstep(0.0, capFadeEndTransition, clamp(globe.transition, 0.0, 1.0));

    CapVertexOut out;
    out.position = clip;
    out.capAlpha = 1.0 - transitionFade;
    out.absLatitude = abs(lat);
    out.latitude = lat;
    out.longitude = lon;
    out.normal = normalize((float4(spherePosition, 0.0) * rotation).xyz);
    out.worldPos = spherePositionTranslated.xyz;
    out.earthNormal = normalize(spherePosition);
    return out;
}

fragment float4 globeCapFragmentShader(CapVertexOut in [[stage_in]],
                                       texture2d<float> texture [[texture(0)]],
                                       constant CapParams& params [[buffer(0)]],
                                       constant Camera& camera [[buffer(1)]],
                                       constant EarthScene& earthScene [[buffer(2)]],
                                       constant Tile& tileData [[buffer(3)]]) {
    constexpr sampler textureSampler(filter::linear, mip_filter::linear, mag_filter::linear);

    float seamBlend = smoothstep(params.blendStartAbsLatitude,
                                 params.blendEndAbsLatitude,
                                 in.absLatitude);
    float4 color;
    if (params.sampleOptions.y > 0.5) {
        GlobeCapAtlasSample sample = globeCapAtlasSampleUV(params.sampleOptions.x,
                                                           in.longitude,
                                                           tileData);
        if (!sample.isValid) {
            discard_fragment();
            return float4(0.0);
        }
        color = texture.sample(textureSampler, sample.uv);
    } else {
        color = mix(params.edgeColor, params.fillColor, seamBlend);
    }

    if (earthScene.isEnabled != 0) {
        float sunDot = dot(normalize(in.earthNormal), normalize(earthScene.sunDirection));
        float dayFactor = smoothstep(-earthScene.terminatorFadeWidth,
                                     earthScene.terminatorFadeWidth,
                                     sunDot);
        float dayBrightness = mix(earthScene.daySideMinimumBrightness, 1.0, dayFactor);
        float surfaceBrightness = mix(earthScene.nightSideBrightness, dayBrightness, dayFactor);
        surfaceBrightness = mix(surfaceBrightness, 1.0, clamp(1.0 - in.capAlpha, 0.0, 1.0));
        surfaceBrightness = mix(surfaceBrightness, 1.0, earthScene.sunShadowFade);
        color.rgb *= surfaceBrightness;

    }

    float3 viewDir = normalize(camera.eye - in.worldPos);
    float rim = pow(max(0.0, 1.0 - dot(in.normal, viewDir)), 2.35);
    float outerGlow = pow(max(0.0, 1.0 - dot(in.normal, viewDir)), 5.2);
    float glowStrength = rim * 0.38 * in.capAlpha;
    float3 glowColor = float3(0.28, 0.54, 1.0) * glowStrength
        + float3(0.08, 0.22, 0.72) * outerGlow * 0.22 * in.capAlpha;

    color.rgb += glowColor;
    color.a *= in.capAlpha;
    return color;
}
