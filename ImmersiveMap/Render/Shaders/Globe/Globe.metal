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
    float2 tileLocalUV;
    float uvSize;
    float posU;
    float posV;
    float lastPos;
    float halfTexel;  // For inset clamping and discard relaxation
    float3 normal;
    float3 worldPos;
    float transition;
    float2 nightLightsUV;
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
    float2 nightLightsUV;
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
    // Night-lights source tiles are Web Mercator (like the day tiles), so the
    // per-tile lookup UV must be Mercator-linear in Y. `vertexIn.uv.y` is linear in
    // the equirect mesh parameter; within a low-zoom tile that spans a large latitude
    // range it diverges from Mercator and drags the lights off the coastlines (worst
    // at z0-3). Rebuild the local V from the vertex's true Mercator position, matching
    // how the day texture derives `t_v`. `sphereV` runs 1 at the north pole to 0 at the
    // south, so `(1 - sphereV)` is the standard north-top global Mercator V; scaling by
    // `zPow` and subtracting `tileY` gives the tile-local [0,1] V. Local U is already
    // Mercator-linear.
    float tileLocalMercatorV = (1.0 - sphereV) * zPow - float(tileY);
    out.tileLocalUV = float2(tileLocalUV.x, tileLocalMercatorV);
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
    out.nightLightsUV = float2(vertexUvX, vertexUvY);
    out.earthNormal = normalize(spherePosition);
    return out;
}

static float3 cinematicNightLightsColor(float core, float halo, float glow) {
    core = saturate(core);
    halo = saturate(halo);
    glow = saturate(glow);

    // Real city light from orbit reads as warm white, not saturated orange: a gentle
    // amber-white in faint areas warming toward near-white at the brightest cores. Kept
    // deliberately pale so dense regions glow rather than turning into a lava sheet.
    float3 dimColor    = float3(1.00, 0.83, 0.60);
    float3 cityColor   = float3(1.00, 0.90, 0.74);
    float3 hotColor    = float3(1.00, 0.97, 0.90);

    float3 tint = mix(dimColor, cityColor, smoothstep(0.15, 0.55, core));
    tint = mix(tint, hotColor, smoothstep(0.6, 0.95, core));

    // Emissive dominated by the actual light (core); the halo and gathered glow only add
    // a gentle same-hue bleed. Modest gain keeps lit regions as punchy points on dark
    // ground instead of a filled, blown-out wash.
    float intensity = pow(core, 1.2) * 1.05
                    + halo * 0.12
                    + glow * 0.22;

    return tint * intensity;
}

struct NightLightsAtlasSample {
    float2 lights;   // x: sharp core, y: sharp halo at the sample point
    float glow;      // wide gathered halo bleed used for the emissive glow
    bool isValid;
};

static bool nightLightsTileCovers(int3 sourceTile, int3 drawnTile) {
    int zoomDelta = drawnTile.z - sourceTile.z;
    if (zoomDelta < 0 || zoomDelta > 20) {
        return false;
    }

    int scale = 1 << zoomDelta;
    return drawnTile.x / scale == sourceTile.x &&
           drawnTile.y / scale == sourceTile.y;
}

static float2 nightLightsSourceTileUV(int3 sourceTile, int3 drawnTile, float2 drawnTileUV) {
    int zoomDelta = drawnTile.z - sourceTile.z;
    if (zoomDelta <= 0) {
        return drawnTileUV;
    }

    int scale = 1 << zoomDelta;
    int2 drawnXY = int2(drawnTile.x, drawnTile.y);
    int2 sourceXY = int2(sourceTile.x, sourceTile.y);
    float2 childOffset = float2(drawnXY - sourceXY * scale);
    return (childOffset + drawnTileUV) / float(scale);
}

static float2 nightLightsAtlasPageLights(uint pageIndex,
                                         float2 uv,
                                         texture2d<float> page0,
                                         texture2d<float> page1,
                                         texture2d<float> page2,
                                         texture2d<float> page3,
                                         texture2d<float> page4,
                                         texture2d<float> page5,
                                         texture2d<float> page6,
                                         texture2d<float> page7) {
    constexpr sampler atlasSampler(filter::linear, address::clamp_to_edge, mip_filter::none);
    switch (pageIndex) {
        case 0:
            return page0.sample(atlasSampler, uv).rg;
        case 1:
            return page1.sample(atlasSampler, uv).rg;
        case 2:
            return page2.sample(atlasSampler, uv).rg;
        case 3:
            return page3.sample(atlasSampler, uv).rg;
        case 4:
            return page4.sample(atlasSampler, uv).rg;
        case 5:
            return page5.sample(atlasSampler, uv).rg;
        case 6:
            return page6.sample(atlasSampler, uv).rg;
        case 7:
            return page7.sample(atlasSampler, uv).rg;
        default:
            return float2(0.0);
    }
}

static NightLightsAtlasSample nightLightsAtlasLights(int3 drawnTile,
                                                     float2 drawnTileUV,
                                                     constant uint2& atlasCounts,
                                                     constant NightLightsAtlasEntry* atlasEntries,
                                                     texture2d<float> page0,
                                                     texture2d<float> page1,
                                                     texture2d<float> page2,
                                                     texture2d<float> page3,
                                                     texture2d<float> page4,
                                                     texture2d<float> page5,
                                                     texture2d<float> page6,
                                                     texture2d<float> page7) {
    uint entryCount = atlasCounts.x;
    uint pageCount = atlasCounts.y;
    float2 selectedLights = float2(0.0);
    int selectedZoom = -1;
    bool hasSample = false;

    // Selected entry parameters, kept so we can gather a wide halo after the best
    // covering tile has been chosen.
    uint selectedPage = 0;
    float2 selectedCenterUV = float2(0.0);
    float2 selectedUVOrigin = float2(0.0);
    float2 selectedUVScale = float2(0.0);

    float2 atlasHalfTexel = 0.5 / float2(page0.get_width(), page0.get_height());

    for (uint index = 0; index < entryCount; ++index) {
        NightLightsAtlasEntry entry = atlasEntries[index];
        int pageIndex = entry.tileAndPage.w;
        if (pageIndex < 0 || uint(pageIndex) >= pageCount) {
            continue;
        }

        int3 sourceTile = int3(entry.tileAndPage.x, entry.tileAndPage.y, entry.tileAndPage.z);
        if (sourceTile.z < selectedZoom || !nightLightsTileCovers(sourceTile, drawnTile)) {
            continue;
        }

        float2 sourceTileUV = nightLightsSourceTileUV(sourceTile, drawnTile, drawnTileUV);
        float2 uvOrigin = entry.uvOriginAndScale.xy;
        float2 uvScale = entry.uvOriginAndScale.zw;
        float2 atlasUV = uvOrigin + clamp(sourceTileUV, float2(0.0), float2(1.0)) * uvScale;
        atlasUV = clamp(atlasUV,
                        uvOrigin + atlasHalfTexel,
                        uvOrigin + uvScale - atlasHalfTexel);
        selectedLights = nightLightsAtlasPageLights(uint(pageIndex),
                                                    atlasUV,
                                                    page0,
                                                    page1,
                                                    page2,
                                                    page3,
                                                    page4,
                                                    page5,
                                                    page6,
                                                    page7);
        selectedZoom = sourceTile.z;
        selectedPage = uint(pageIndex);
        selectedCenterUV = atlasUV;
        selectedUVOrigin = uvOrigin;
        selectedUVScale = uvScale;
        hasSample = true;
    }

    // Spread a soft emissive bleed by gathering the pre-blurred halo channel in two
    // rings around the sample - a cheap, tile-local approximation of a bloom that lets
    // city light leak beyond its source texels. Gated on there being light at all so
    // the dark ocean/countryside pays nothing.
    float glow = 0.0;
    if (hasSample && (selectedLights.x + selectedLights.y) > 0.004) {
        float2 minUV = selectedUVOrigin + atlasHalfTexel;
        float2 maxUV = selectedUVOrigin + selectedUVScale - atlasHalfTexel;
        float glowAccum = selectedLights.y;
        float glowWeight = 1.0;
        for (int ring = 0; ring < 2; ++ring) {
            float radius = selectedUVScale.x * (ring == 0 ? 0.012 : 0.028);
            float ringWeight = (ring == 0 ? 0.7 : 0.35);
            for (int tap = 0; tap < 8; ++tap) {
                float angle = (float(tap) / 8.0) * 6.28318530718;
                float2 offset = float2(cos(angle), sin(angle)) * radius;
                float2 tapUV = clamp(selectedCenterUV + offset, minUV, maxUV);
                float tapHalo = nightLightsAtlasPageLights(selectedPage,
                                                           tapUV,
                                                           page0,
                                                           page1,
                                                           page2,
                                                           page3,
                                                           page4,
                                                           page5,
                                                           page6,
                                                           page7).y;
                glowAccum += tapHalo * ringWeight;
                glowWeight += ringWeight;
            }
        }
        glow = glowAccum / glowWeight;
    }

    return NightLightsAtlasSample{selectedLights, glow, hasSample};
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
                                    texture2d<float> nightLightsAtlasPage0 [[texture(1)]],
                                    texture2d<float> nightLightsAtlasPage1 [[texture(2)]],
                                    texture2d<float> nightLightsAtlasPage2 [[texture(3)]],
                                    texture2d<float> nightLightsAtlasPage3 [[texture(4)]],
                                    texture2d<float> nightLightsAtlasPage4 [[texture(5)]],
                                    texture2d<float> nightLightsAtlasPage5 [[texture(6)]],
                                    texture2d<float> nightLightsAtlasPage6 [[texture(7)]],
                                    texture2d<float> nightLightsAtlasPage7 [[texture(8)]],
                                    constant Camera& camera [[buffer(1)]],
                                    constant EarthScene& earthScene [[buffer(2)]],
                                    constant Tile& tileData [[buffer(3)]],
                                    constant uint2& nightLightsAtlasCounts [[buffer(4)]],
                                    constant NightLightsAtlasEntry* nightLightsAtlasEntries [[buffer(5)]],
                                    constant HorizonFog& horizonFog [[buffer(6)]]) {
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

        if (earthScene.nightLightsEnabled != 0) {
            float nightFactor = 1.0 - smoothstep(-earthScene.nightLightsTerminatorFadeWidth,
                                                 earthScene.nightLightsTerminatorFadeWidth,
                                                 sunDot);
            NightLightsAtlasSample atlasSample = nightLightsAtlasLights(tileData.tile,
                                                                        in.tileLocalUV,
                                                                        nightLightsAtlasCounts,
                                                                        nightLightsAtlasEntries,
                                                                        nightLightsAtlasPage0,
                                                                        nightLightsAtlasPage1,
                                                                        nightLightsAtlasPage2,
                                                                        nightLightsAtlasPage3,
                                                                        nightLightsAtlasPage4,
                                                                        nightLightsAtlasPage5,
                                                                        nightLightsAtlasPage6,
                                                                        nightLightsAtlasPage7);
            float2 lights = atlasSample.isValid ? atlasSample.lights : float2(0.0);
            float glow = atlasSample.isValid ? atlasSample.glow : 0.0;
            float nightLightsGain = nightFactor * earthScene.nightLightsIntensity * (1.0 - in.transition) * (1.0 - earthScene.sunShadowFade);

            float3 lightColor = cinematicNightLightsColor(lights.x, lights.y, glow);
            color.rgb += lightColor * nightLightsGain;

            // Atmospheric scatter: at grazing view angles the lit ground is seen through
            // far more air, so cities near the limb bleed a warm haze into the atmosphere.
            // This is view-dependent, so it reacts to the camera the way real orbital
            // imagery does - the key cue that separates "light" from "pasted texture".
            float3 nightViewDir = normalize(camera.eye - in.worldPos);
            float grazing = pow(1.0 - saturate(dot(normalize(in.normal), nightViewDir)), 3.5);
            float lightPresence = saturate(lights.x * 1.5 + lights.y + glow);
            float3 scatterColor = float3(1.0, 0.78, 0.52);
            color.rgb += scatterColor * grazing * lightPresence * 0.22 * nightLightsGain;
        }
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
    out.nightLightsUV = float2(globeCapWrapUnit(lon / (2.0 * M_PI_F)),
                               1.0 - (lat + M_PI_2_F) / M_PI_F);
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
