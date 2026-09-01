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

// Star attributes are unit-range (phase is 0..2pi), so the interpolants ride
// as half: cheaper interpolation and half-rate fragment math on A-series GPUs,
// identical rate on M-series.
struct StarVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    half brightness;
    half temperature;
    half twinklePhase;
    half halo;
    half transition;
};

struct StarfieldParams {
    /// The globe's pan rotation, row-vector layout (`v * M`), computed once
    /// per frame on the CPU.
    float4x4 rotation;
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
    /// The globe's pan rotation, row-vector layout (`v * M`), computed once
    /// per frame on the CPU.
    float4x4 rotation;
    float aspect;
    float tanHalfFov;
    float2 padding;
};

/// The equirect parametrization the nebula bake and its runtime sample
/// share: longitude across, latitude down, in the earth-fixed frame the
/// noise lattice lives in.
static inline float2 starfieldEquirectUV(float3 direction) {
    float longitude = atan2(direction.x, -direction.z);
    float latitude = asin(clamp(direction.y, -1.0, 1.0));
    return float2(longitude / (2.0 * M_PI_F) + 0.5, latitude / M_PI_F + 0.5);
}

static inline float3 starfieldEquirectDirection(float2 uv) {
    float longitude = (uv.x - 0.5) * 2.0 * M_PI_F;
    float latitude = (uv.y - 0.5) * M_PI_F;
    float cosLatitude = cos(latitude);
    return float3(cosLatitude * sin(longitude), sin(latitude), -cosLatitude * cos(longitude));
}

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

BackgroundVertexOut makeFullscreenTriangleVertex(uint vertexID) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    BackgroundVertexOut out;
    float2 clip = positions[vertexID];
    // At the far plane on purpose: the sky layers draw after the globe
    // surface and depth-test lessEqual, so a cleared pixel (space) passes
    // and a pixel the sphere covered rejects the fragment before it shades.
    out.position = float4(clip, 1.0, 1.0);
    out.uv = clip * 0.5 + 0.5;
    return out;
}

vertex BackgroundVertexOut starfieldBackgroundVertexShader(uint vertexID [[vertex_id]]) {
    return makeFullscreenTriangleVertex(vertexID);
}

/// The nebula bake: the whole background composition below is a pure
/// function of the earth-fixed view direction, so it is evaluated once per
/// process into an equirect texture and the per-frame background pass
/// becomes one sample. Five fractal noise fields (sixteen hashes each) per
/// texel run here, at bake time, instead of per pixel per frame.
fragment float4 starfieldNebulaBakeFragmentShader(BackgroundVertexOut in [[stage_in]],
                                                  constant BackgroundParams& params [[buffer(0)]]) {
    float3 localDirection = starfieldEquirectDirection(in.uv);

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
    // The noise lattice above needs float (hash21 works on large coordinates);
    // the composition below is unit-range and runs in half.
    half nebulaA = smoothstep(0.56h, 0.83h, half(largeNoise))
        * (half(band) * 0.65h + half(directionalLift) * 0.28h);
    half nebulaB = smoothstep(0.60h, 0.88h, half(detailNoise))
        * (half(band) * 0.45h + half(wisps) * 0.22h);

    half3 color = half3(params.deepColor.rgb);
    color += half3(params.hazeColor.rgb) * (half(band) * 0.18h + half(directionalLift) * 0.12h);
    color += half3(params.nebulaColorA.rgb) * nebulaA * half(params.controls.z);
    color += half3(params.nebulaColorB.rgb) * nebulaB * half(params.controls.z) * 0.85h;
    color *= 1.0h - half(smoothstep(0.15, 0.98, abs(localDirection.y))) * half(params.controls.x) * 0.22h;

    return float4(float3(color), 1.0);
}

/// The per-frame background: rotate the pixel's view ray into the
/// earth-fixed frame with the CPU-computed pan rotation and sample the
/// baked nebula there; only the flat-map transition mix stays live.
fragment float4 starfieldBackgroundFragmentShader(BackgroundVertexOut in [[stage_in]],
                                                  constant BackgroundParams& params [[buffer(0)]],
                                                  constant BackgroundViewParams& viewParams [[buffer(1)]],
                                                  constant Globe& globe [[buffer(2)]],
                                                  texture2d<half> nebulaTexture [[texture(0)]]) {
    // Repeat across the longitude seam, clamp at the poles.
    constexpr sampler nebulaSampler(coord::normalized,
                                    s_address::repeat,
                                    t_address::clamp_to_edge,
                                    filter::linear);
    float2 uv = in.uv * 2.0 - 1.0;
    float3 baseViewDirection = normalize(float3(uv.x * viewParams.aspect * viewParams.tanHalfFov,
                                                uv.y * viewParams.tanHalfFov,
                                                -1.0));
    float3 localDirection = normalize((float4(baseViewDirection, 0.0) * transpose(viewParams.rotation)).xyz);

    half3 color = nebulaTexture.sample(nebulaSampler, starfieldEquirectUV(localDirection)).rgb;
    half transitionFade = smoothstep(0.0h, 1.0h, half(globe.transition));
    color = mix(color, half3(params.transitionTargetColor.rgb), transitionFade);

    return float4(float3(color), 1.0);
}

vertex StarVertexOut starfieldVertexShader(StarVertexIn in [[stage_in]],
                                           constant Camera& camera [[buffer(1)]],
                                           constant Globe& globe [[buffer(2)]],
                                           constant StarfieldParams& params [[buffer(3)]]) {
    StarVertexOut out;
    float starRadius = globe.radius * params.radiusScale;
    float4 world = float4(in.position * starRadius, 1.0) * params.rotation * translationMatrix(float3(0, 0, -globe.radius));
    out.position = camera.matrix * world;
    // Stars are background: forced to the far plane so the sky depth test
    // (see makeFullscreenTriangleVertex) rejects them wherever the globe
    // surface has written depth.
    out.position.z = out.position.w;
    float sizeScale = starRadius / globe.radius;
    out.pointSize = max(1.2, in.size * sizeScale * 0.32);
    out.brightness = half(in.brightness);
    out.temperature = half(in.temperature);
    out.twinklePhase = half(in.twinklePhase);
    out.halo = half(in.halo);
    out.transition = half(globe.transition);
    return out;
}

fragment float4 starfieldFragmentShader(StarVertexOut in [[stage_in]],
                                        float2 pointCoord [[point_coord]],
                                        constant float &time [[buffer(0)]]) {
    half2 centered = half2(pointCoord) * 2.0h - 1.0h;
    half radiusSquared = dot(centered, centered);
    if (radiusSquared > 1.0h) {
        discard_fragment();
    }

    // All terms are unit-range, so the whole sprite evaluates in half. The
    // twinkle argument stays float: time grows unbounded and would lose the
    // phase entirely at half precision.
    half core = exp(-radiusSquared * 7.8h);
    half halo = exp(-radiusSquared * 2.35h) * (0.45h + in.halo * 0.95h);
    half crossGlow = exp(-abs(centered.x * centered.y) * 10.0h) * 0.08h * in.halo;
    half twinkle = 0.9h + 0.1h * half(sin(time * (1.0 + float(in.halo) * 1.3) + float(in.twinklePhase)));
    half intensity = in.brightness * twinkle;

    half3 warm = half3(1.0h, 0.88h, 0.78h);
    half3 neutral = half3(0.96h, 0.97h, 1.0h);
    half3 cool = half3(0.72h, 0.83h, 1.0h);
    half clampedTemperature = clamp(in.temperature, 0.0h, 1.0h);
    half3 color = clampedTemperature < 0.5h
        ? mix(warm, neutral, clampedTemperature * 2.0h)
        : mix(neutral, cool, (clampedTemperature - 0.5h) * 2.0h);

    half transitionAlpha = 1.0h - smoothstep(0.0h, 1.0h, in.transition);
    half alpha = saturate(core * 0.95h + halo * 0.55h + crossGlow) * intensity * transitionAlpha;
    half3 emissive = color * (core * 1.3h + halo * 0.75h + crossGlow * 1.6h) * intensity * transitionAlpha;
    return float4(float3(emissive), float(alpha));
}
