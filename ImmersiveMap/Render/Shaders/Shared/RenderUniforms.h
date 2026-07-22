// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderUniforms.h
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;

#ifndef RENDER_UNIFORMS
#define RENDER_UNIFORMS

struct Camera {
    float4x4 matrix;
    float3 eye;
    float _padding;
};

struct Globe {
    float panX;
    float panY;
    float radius;
    float transition;
};

struct EarthScene {
    float3 sunDirection;
    uint isEnabled;
    float daySideMinimumBrightness;
    float nightSideBrightness;
    float terminatorFadeWidth;
    uint sunVisualEnabled;
    float sunDiskAngularSize;
    float sunDiskIntensity;
    float sunGlowIntensity;
    float sunEdgeGlareIntensity;
    float sunLimbHaloIntensity;
    float sunLimbHaloWidth;
    float sunShadowFade;
    uint _padding0;
};

struct SunVisualState {
    float2 screenCenter;
    float2 clampedScreenCenter;
    float2 globeScreenCenter;
    float globeScreenRadius;
    float diskAlpha;
    float edgeGlareAlpha;
    float limbHaloAlpha;
    uint isEnabled;
    uint padding;
};

// Дымка у горизонта плоского представления; раскладка зеркалит
// HorizonFogUniform.swift. Дистанции измеряются в высотах глаза над
// плоскостью, поэтому полоса тумана геометрически приклеена к линии схода
// и не зависит ни от зума, ни от смены рендерного масштаба на целых зумах.
struct HorizonFog {
    float3 color;
    float3 eye;
    float strength;
    float startEyeHeights;
    float endEyeHeights;
    float _padding;
};

static inline float3 applyHorizonFog(float3 color,
                                     constant HorizonFog& fog,
                                     float3 worldPos) {
    float eyeHeight = max(abs(fog.eye.z), 1e-4);
    float distanceToEye = length(worldPos - fog.eye);
    float fogAmount = smoothstep(fog.startEyeHeights * eyeHeight,
                                 fog.endEyeHeights * eyeHeight,
                                 distanceToEye) * fog.strength;
    return mix(color, fog.color, fogAmount);
}

#endif
