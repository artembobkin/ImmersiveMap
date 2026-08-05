// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"

// The sphere-plane morph is evaluated on the CPU (GeoSurfaceFrameMath), so the
// sample buffer already holds world positions. This shader only expands the
// centerline into a ribbon whose width is constant in drawable pixels, and cuts
// it into dashes measured along the projected centerline.

struct RouteUniform {
    float2 viewport;
    /// Half of the ribbon width, in drawable pixels; already floored at 0.5 on
    /// the CPU, which is where sub-pixel widths are traded for alpha instead.
    float halfWidthPx;
    uint sampleCount;
    /// Straight (non-premultiplied) RGBA.
    float4 color;
    /// Drawn part of one dash period, in drawable pixels. Zero draws a solid
    /// line.
    float dashPx;
    /// Gap of one dash period, in drawable pixels.
    float gapPx;
    float2 _padding;
};

/// The quad is rasterized half a pixel wider than the true half width on each
/// side, so the antialiasing band lies inside the geometry and is never clipped.
constant float kRouteFeatherPx = 0.5;
/// Below this clip-space w the manual perspective divide is meaningless.
constant float kRouteMinimumW = 1e-4;

struct RouteVertexOut {
    float4 position [[position]];
    /// Signed distance from the centerline, in pixels. Both side vertices of a
    /// sample keep the same w, so this interpolates exactly linearly across the
    /// ribbon and the coverage below is analytic.
    float offsetPx;
    /// Distance along the projected centerline, in pixels. Interpolated without
    /// perspective correction on purpose: it is a screen-space quantity, and
    /// perspective-correct interpolation would compress dashes on segments
    /// receding from the camera.
    float arcPx [[center_no_perspective]];
};

vertex RouteVertexOut routeVertexShader(uint vid [[vertex_id]],
                                        const device float4* samples [[buffer(0)]],
                                        constant Camera& camera [[buffer(1)]],
                                        constant RouteUniform& route [[buffer(2)]],
                                        const device float* screenLengths [[buffer(3)]]) {
    uint last = route.sampleCount > 0u ? route.sampleCount - 1u : 0u;
    uint index = min(vid >> 1, last);
    float side = (vid & 1u) == 0u ? 1.0 : -1.0;
    uint previousIndex = index == 0u ? 0u : index - 1u;
    uint nextIndex = index >= last ? last : index + 1u;

    RouteVertexOut out;
    out.offsetPx = side * (route.halfWidthPx + kRouteFeatherPx);
    out.arcPx = screenLengths[index];

    float4 clip = camera.matrix * float4(samples[index].xyz, 1.0);
    // At the near plane both side vertices collapse onto the centerline: the
    // ribbon pinches to a point instead of smearing across the screen.
    if (clip.w <= kRouteMinimumW) {
        out.position = clip;
        return out;
    }

    float4 clipPrevious = camera.matrix * float4(samples[previousIndex].xyz, 1.0);
    float4 clipNext = camera.matrix * float4(samples[nextIndex].xyz, 1.0);

    float2 halfViewport = route.viewport * 0.5;
    float2 centerPx = (clip.xy / clip.w) * halfViewport;
    float2 previousPx = clipPrevious.w > kRouteMinimumW
        ? (clipPrevious.xy / clipPrevious.w) * halfViewport
        : centerPx;
    float2 nextPx = clipNext.w > kRouteMinimumW
        ? (clipNext.xy / clipNext.w) * halfViewport
        : centerPx;

    // Central difference: the normal belongs to the SAMPLE, so neighbouring
    // quads share both vertices and the strip has no gaps at the joins.
    float2 tangent = nextPx - previousPx;
    float tangentLength = length(tangent);
    float2 direction = tangentLength > 1e-5 ? tangent / tangentLength : float2(1.0, 0.0);
    float2 normal = float2(-direction.y, direction.x);

    // Multiplying by w survives the perspective divide that follows.
    clip.xy += (normal * out.offsetPx / halfViewport) * clip.w;
    out.position = clip;
    return out;
}

/// Coverage of the dash pattern at `arcPx`, antialiased with the same half
/// pixel band as the ribbon edges. A zero period draws a solid line.
static inline float routeDashCoverage(float arcPx, float dashPx, float gapPx) {
    float period = dashPx + gapPx;
    if (period <= 0.0 || dashPx <= 0.0) {
        return 1.0;
    }
    if (gapPx <= 0.0) {
        return 1.0;
    }
    // Signed distance to the nearest dash boundary, wrapped around the period:
    // a raw fmod would leave the leading edge of every dash without the lower
    // half of its antialiasing band and step from 0 to 0.5 in one pixel.
    float phase = fmod(arcPx, period);
    if (phase < 0.0) {
        phase += period;
    }
    float centered = phase - dashPx * 0.5;
    centered -= period * round(centered / period);
    float distanceToEdge = dashPx * 0.5 - abs(centered);
    return smoothstep(-0.5, 0.5, distanceToEdge);
}

fragment float4 routeFragmentShader(RouteVertexOut in [[stage_in]],
                                    constant RouteUniform& route [[buffer(0)]]) {
    float distancePx = route.halfWidthPx - abs(in.offsetPx);
    float coverage = smoothstep(-0.5, 0.5, distancePx);
    coverage *= routeDashCoverage(in.arcPx, route.dashPx, route.gapPx);
    return float4(route.color.rgb, route.color.a * coverage);
}
