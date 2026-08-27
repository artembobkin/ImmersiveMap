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
    half transitionFade = smoothstep(0.0h, 1.0h, half(globe.transition));
    color = mix(color, half3(params.transitionTargetColor.rgb), transitionFade);

    return float4(float3(color), 1.0);
}

vertex BackgroundVertexOut sunVertexShader(uint vertexID [[vertex_id]]) {
    return makeFullscreenTriangleVertex(vertexID);
}

/// The visible sun. There is no air in space, so the sky around it stays
/// black: no sunset glow spread across the frame. But the sun is drawn the
/// way the photographs everyone knows show it, warm rather than spectrally
/// white: a white centre going gold through the disc and amber in a short
/// bloom, so the disc has a gradient to sit in. The drama of a sun behind
/// the planet is in the limb: the atmosphere lit from behind draws a ring,
/// sky-blue away from the sun, warming through amber to a white-gold focus
/// where the disc is about to break through, and at that focus a flare
/// elongated along the limb (the diamond ring). The ring is a full circle
/// with the sun straight behind and narrows to a crescent as the sun comes
/// round toward the limb.
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
    // Screen-space distances stay float; the falloff composition runs in half.
    // The distance ratios overflow half only where exp() underflows to zero
    // anyway, so the result is unchanged.
    half diskT = half(diskDistance / diskRadius);
    half diskAlpha = half(sun.diskAlpha) * half(earth.sunDiskIntensity);
    half coreCenter = exp(-diskT * diskT * 8.0h) * diskAlpha;
    half core = exp(-diskT * diskT * 2.6h) * diskAlpha;
    // The bloom reaches under two disc radii past the disc and no further.
    half glowT = diskT * (1.0h / 1.8h);
    half glow = exp(-glowT * glowT) * half(sun.diskAlpha);

    float edgeDistance = length((uv - sun.clampedScreenCenter) * aspectScale);
    half edgeGlare = exp(half(-edgeDistance) * 8.0h) * half(sun.edgeGlareAlpha) * half(earth.sunEdgeGlareIntensity);

    float globeDistance = length((uv - sun.globeScreenCenter) * aspectScale);
    float limbDistance = abs(globeDistance - sun.globeScreenRadius);
    float2 limbVector = (uv - sun.globeScreenCenter) * aspectScale;
    float2 sunVector = (sun.screenCenter - sun.globeScreenCenter) * aspectScale;
    float limbVectorLength = length(limbVector);
    float sunVectorLength = length(sunVector);
    float2 limbDirection = limbVector / max(limbVectorLength, 0.0001);
    float2 sunDirection = sunVector / max(sunVectorLength, 0.0001);
    float limbAlignment = dot(limbDirection, sunDirection);
    // 0 with the sun straight behind the globe (a full ring), 1 with it at the
    // limb (a tight crescent on the sun's side).
    float closeness = clamp(sunVectorLength / max(sun.globeScreenRadius, 0.0001), 0.0, 1.0);
    float crescentStart = mix(-1.0, 0.25, closeness);
    float crescentEnd = mix(-0.6, 0.95, closeness);
    float directionalLimb = smoothstep(crescentStart, crescentEnd, limbAlignment);
    float haloWidth = max(earth.sunLimbHaloWidth, 0.001);
    half limbT = half(limbDistance / haloWidth);
    // A thin bright edge and a faint skirt outside it, so the far side of the
    // ring stays a clean line and the focus stands out against it.
    half limbEdge = exp(-limbT * limbT * 6.0h);
    half limbSkirt = exp(-limbT * limbT * 1.2h);
    half limbHaloAlpha = half(sun.limbHaloAlpha) * half(earth.sunLimbHaloIntensity);
    half limb = (limbEdge + 0.15h * limbSkirt) * half(directionalLimb) * limbHaloAlpha;

    // The focus: the point of the limb nearest the sun. A flare sits there,
    // elongated along the limb tangent, only while the sun is near the limb.
    float2 focus = sun.globeScreenCenter * aspectScale + sunDirection * sun.globeScreenRadius;
    float2 tangent = float2(-sunDirection.y, sunDirection.x);
    float2 toFocus = uv * aspectScale - focus;
    float flareAcross = dot(toFocus, sunDirection) / (haloWidth * 1.5);
    float flareAlong = dot(toFocus, tangent) / (haloWidth * 4.5);
    half flare = exp(half(-(flareAcross * flareAcross + flareAlong * flareAlong)))
        * half(smoothstep(0.35, 0.9, closeness))
        * limbHaloAlpha;

    // Colour temperature along the crescent: sky-blue away from the sun,
    // amber as it wraps toward it, white-gold at the focus.
    float warmth = smoothstep(0.0, 1.0, limbAlignment) * closeness;
    half3 ringSky = half3(0.45h, 0.70h, 1.0h);
    half3 ringAmber = half3(1.0h, 0.70h, 0.35h);
    half3 ringHot = half3(1.0h, 0.95h, 0.85h);
    half3 ringColor = mix(ringSky, ringAmber, half(smoothstep(0.3, 0.9, warmth)));
    ringColor = mix(ringColor, ringHot, half(smoothstep(0.85, 1.0, warmth)));

    half3 sunWhite = half3(1.0h, 0.99h, 0.96h);
    half3 sunGold = half3(1.0h, 0.85h, 0.55h);
    half3 bloomAmber = half3(1.0h, 0.72h, 0.40h);
    half3 flareGold = half3(1.0h, 0.90h, 0.70h);
    half3 orangeGlow = half3(1.0h, 0.45h, 0.12h);

    half glowIntensity = half(earth.sunGlowIntensity);
    half3 color = mix(sunGold, sunWhite, coreCenter) * core
        + bloomAmber * glow * glowIntensity
        + orangeGlow * edgeGlare
        + ringColor * limb
        + flareGold * flare;
    half alpha = saturate(core + glow * glowIntensity * 0.7h + edgeGlare * 0.45h + limb * 0.8h + flare * 0.9h);
    return float4(float3(color), float(alpha));
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
