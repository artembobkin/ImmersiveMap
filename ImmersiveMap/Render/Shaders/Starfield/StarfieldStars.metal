// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../Shared/RenderUniforms.h"
#include "../Shared/GeoMath.h"

struct BackgroundVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct StarVertexIn {
    float3 position [[attribute(0)]];
    float size [[attribute(1)]];
    float brightness [[attribute(2)]];
    float temperature [[attribute(3)]];
    float twinklePhase [[attribute(4)]];
    float halo [[attribute(5)]];
};

struct StarVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float brightness;
    float temperature;
    float twinklePhase;
    float halo;
    float transition;
};

struct StarfieldParams {
    float radiusScale;
    float3 padding;
};

struct BackgroundParams {
    float4 deepColor;
    float4 hazeColor;
    float4 nebulaColorA;
    float4 nebulaColorB;
    float4 transitionTargetColor;
    float4 controls;
};

struct BackgroundViewParams {
    float aspect;
    float tanHalfFov;
    float2 padding;
};

float hash21(float2 value) {
    value = fract(value * float2(123.34, 345.45));
    value += dot(value, value + 34.345);
    return fract(value.x * value.y);
}

float valueNoise(float2 uv) {
    float2 cell = floor(uv);
    float2 local = fract(uv);
    float2 smooth = local * local * (3.0 - 2.0 * local);

    float a = hash21(cell);
    float b = hash21(cell + float2(1.0, 0.0));
    float c = hash21(cell + float2(0.0, 1.0));
    float d = hash21(cell + float2(1.0, 1.0));

    return mix(mix(a, b, smooth.x), mix(c, d, smooth.x), smooth.y);
}

float fractalNoise(float2 uv) {
    float sum = 0.0;
    float amplitude = 0.55;

    for (uint octave = 0; octave < 4; octave++) {
        sum += valueNoise(uv) * amplitude;
        uv = uv * 2.03 + float2(3.1, -1.7);
        amplitude *= 0.5;
    }

    return sum;
}

float4x4 starfieldRotationMatrix(Globe globe) {
    float maxLatitude = 2.0 * atan(exp(M_PI_F)) - M_PI_2_F;
    float latitude = globe.panY * maxLatitude;
    float longitude = globe.panX * M_PI_F;

    float cx = cos(-latitude);
    float sx = sin(-latitude);
    float cy = cos(-longitude);
    float sy = sin(-longitude);

    return float4x4(
        float4(cy,        0,         -sy,       0),
        float4(sy * sx,   cx,        cy * sx,   0),
        float4(sy * cx,  -sx,        cy * cx,   0),
        float4(0,         0,          0,        1)
    );
}

BackgroundVertexOut makeFullscreenTriangleVertex(uint vertexID) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    BackgroundVertexOut out;
    float2 clip = positions[vertexID];
    out.position = float4(clip, 0.0, 1.0);
    out.uv = clip * 0.5 + 0.5;
    return out;
}

vertex BackgroundVertexOut starfieldBackgroundVertexShader(uint vertexID [[vertex_id]]) {
    return makeFullscreenTriangleVertex(vertexID);
}

fragment float4 starfieldBackgroundFragmentShader(BackgroundVertexOut in [[stage_in]],
                                                  constant BackgroundParams& params [[buffer(0)]],
                                                  constant BackgroundViewParams& viewParams [[buffer(1)]],
                                                  constant Globe& globe [[buffer(2)]]) {
    float2 uv = in.uv * 2.0 - 1.0;
    float4x4 rotation = starfieldRotationMatrix(globe);
    float3 baseViewDirection = normalize(float3(uv.x * viewParams.aspect * viewParams.tanHalfFov,
                                                uv.y * viewParams.tanHalfFov,
                                                -1.0));
    float3 localDirection = normalize((float4(baseViewDirection, 0.0) * transpose(rotation)).xyz);

    float3 directionWeights = pow(abs(localDirection), float3(2.4));
    float weightSum = max(directionWeights.x + directionWeights.y + directionWeights.z, 0.0001);
    directionWeights /= weightSum;

    float projectionXY = fractalNoise(localDirection.xy * params.controls.y + float2(2.8, -1.4));
    float projectionYZ = fractalNoise(localDirection.yz * (params.controls.y * 1.07) + float2(-4.2, 1.9));
    float projectionZX = fractalNoise(localDirection.zx * (params.controls.y * 0.78) + float2(1.3, -2.6));
    float largeNoise = projectionXY * directionWeights.z
        + projectionYZ * directionWeights.x
        + projectionZX * directionWeights.y;
    float detailNoise = fractalNoise((localDirection.xy + localDirection.zx) * (params.controls.y * 1.4) + float2(-1.2, 3.4));
    float band = pow(clamp(1.0 - abs(localDirection.y + 0.08), 0.0, 1.0), 4.5);
    float directionalLift = pow(clamp(1.0 - abs(localDirection.y - 0.28), 0.0, 1.0), 2.6);
    float wisps = fractalNoise(float2(localDirection.z, localDirection.x) * (params.controls.y * 0.75) + float2(1.3, -2.6));
    float nebulaA = smoothstep(0.56, 0.83, largeNoise) * (band * 0.65 + directionalLift * 0.28);
    float nebulaB = smoothstep(0.60, 0.88, detailNoise) * (band * 0.45 + wisps * 0.22);

    float3 color = params.deepColor.rgb;
    color += params.hazeColor.rgb * (band * 0.18 + directionalLift * 0.12);
    color += params.nebulaColorA.rgb * nebulaA * params.controls.z;
    color += params.nebulaColorB.rgb * nebulaB * params.controls.z * 0.85;
    color *= 1.0 - smoothstep(0.15, 0.98, abs(localDirection.y)) * params.controls.x * 0.22;
    float transitionFade = smoothstep(0.0, 1.0, globe.transition);
    color = mix(color, params.transitionTargetColor.rgb, transitionFade);

    return float4(color, 1.0);
}

vertex BackgroundVertexOut sunVertexShader(uint vertexID [[vertex_id]]) {
    return makeFullscreenTriangleVertex(vertexID);
}

fragment float4 sunFragmentShader(BackgroundVertexOut in [[stage_in]],
                                  constant EarthScene& earth [[buffer(0)]],
                                  constant SunVisualState& sun [[buffer(1)]]) {
    if (earth.isEnabled == 0 || earth.sunVisualEnabled == 0 || sun.isEnabled == 0) {
        return float4(0.0);
    }

    float2 uv = in.uv;
    float viewportAspect = max(fwidth(uv.y), 0.000001) / max(fwidth(uv.x), 0.000001);
    float2 aspectScale = float2(viewportAspect, 1.0);

    float diskDistance = length((uv - sun.screenCenter) * aspectScale);
    float diskRadius = max(earth.sunDiskAngularSize, 0.001);
    float core = exp(-pow(diskDistance / diskRadius, 2.0) * 2.6) * sun.diskAlpha * earth.sunDiskIntensity;
    float glow = exp(-pow(diskDistance / (diskRadius * 3.5), 2.0)) * sun.diskAlpha;

    float edgeDistance = length((uv - sun.clampedScreenCenter) * aspectScale);
    float edgeGlare = exp(-edgeDistance * 8.0) * sun.edgeGlareAlpha * earth.sunEdgeGlareIntensity;

    float globeDistance = length((uv - sun.globeScreenCenter) * aspectScale);
    float limbDistance = abs(globeDistance - sun.globeScreenRadius);
    float2 limbVector = (uv - sun.globeScreenCenter) * aspectScale;
    float2 sunVector = (sun.screenCenter - sun.globeScreenCenter) * aspectScale;
    float limbVectorLength = length(limbVector);
    float sunVectorLength = length(sunVector);
    float2 limbDirection = limbVector / max(limbVectorLength, 0.0001);
    float2 sunDirection = sunVector / max(sunVectorLength, 0.0001);
    float limbAlignment = dot(limbDirection, sunDirection);
    float directionalLimb = sunVectorLength > 0.0001 ? smoothstep(0.18, 0.92, limbAlignment) : 0.0;
    float limb = exp(-pow(limbDistance / max(earth.sunLimbHaloWidth, 0.001), 2.0) * 6.0)
        * sun.limbHaloAlpha
        * directionalLimb
        * earth.sunLimbHaloIntensity;

    float3 warmCore = float3(1.0, 0.94, 0.72);
    float3 orangeGlow = float3(1.0, 0.45, 0.12);
    float3 color = warmCore * core
        + orangeGlow * glow * earth.sunGlowIntensity
        + orangeGlow * edgeGlare
        + warmCore * limb;
    float alpha = saturate(core + glow * earth.sunGlowIntensity * 0.7 + edgeGlare * 0.45 + limb * 0.55);
    return float4(color, alpha);
}

vertex StarVertexOut starfieldVertexShader(StarVertexIn in [[stage_in]],
                                           constant Camera& camera [[buffer(1)]],
                                           constant Globe& globe [[buffer(2)]],
                                           constant StarfieldParams& params [[buffer(3)]]) {
    StarVertexOut out;
    float4x4 rotation = starfieldRotationMatrix(globe);

    float starRadius = globe.radius * params.radiusScale;
    float4 world = float4(in.position * starRadius, 1.0) * rotation * translationMatrix(float3(0, 0, -globe.radius));
    out.position = camera.matrix * world;
    float sizeScale = starRadius / globe.radius;
    out.pointSize = max(1.2, in.size * sizeScale * 0.32);
    out.brightness = in.brightness;
    out.temperature = in.temperature;
    out.twinklePhase = in.twinklePhase;
    out.halo = in.halo;
    out.transition = globe.transition;
    return out;
}

fragment float4 starfieldFragmentShader(StarVertexOut in [[stage_in]],
                                        float2 pointCoord [[point_coord]],
                                        constant float &time [[buffer(0)]]) {
    float2 centered = pointCoord * 2.0 - 1.0;
    float radiusSquared = dot(centered, centered);
    if (radiusSquared > 1.0) {
        discard_fragment();
    }

    float core = exp(-radiusSquared * 7.8);
    float halo = exp(-radiusSquared * 2.35) * (0.45 + in.halo * 0.95);
    float crossGlow = exp(-abs(centered.x * centered.y) * 10.0) * 0.08 * in.halo;
    float twinkle = 0.9 + 0.1 * sin(time * (1.0 + in.halo * 1.3) + in.twinklePhase);
    float intensity = in.brightness * twinkle;

    float3 warm = float3(1.0, 0.88, 0.78);
    float3 neutral = float3(0.96, 0.97, 1.0);
    float3 cool = float3(0.72, 0.83, 1.0);
    float clampedTemperature = clamp(in.temperature, 0.0, 1.0);
    float3 color = clampedTemperature < 0.5
        ? mix(warm, neutral, clampedTemperature * 2.0)
        : mix(neutral, cool, (clampedTemperature - 0.5) * 2.0);

    float transitionAlpha = 1.0 - smoothstep(0.0, 1.0, in.transition);
    float alpha = saturate(core * 0.95 + halo * 0.55 + crossGlow) * intensity * transitionAlpha;
    float3 emissive = color * (core * 1.3 + halo * 0.75 + crossGlow * 1.6) * intensity * transitionAlpha;
    return float4(emissive, alpha);
}
