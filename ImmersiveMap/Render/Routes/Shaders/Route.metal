// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Shaders/Shared/RenderUniforms.h"
#include "../../Shaders/Globe/GlobeTransitionProjection.h"

// The sphere-plane morph is evaluated on the CPU (GeoSurfaceFrameMath), so the
// sample buffer already holds world positions. This shader only expands the
// centerline into a ribbon whose width is constant in drawable pixels, cuts it
// into dashes measured along the projected centerline, and drops what the body
// of the globe stands in front of.

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
/// Width of the horizon ramp, as a fraction of the globe radius by which the
/// line of sight clears the surface. The band lies entirely on the visible
/// side, so nothing is painted past the limb; it exists only so the cut is
/// antialiased instead of stepping one sample at a time as the globe turns.
/// Near the limb the projection compresses this to a fraction of a pixel.
constant float kRouteHorizonBand = 0.0015;

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
    /// World position of the centerline at this fragment. Both side vertices of
    /// a sample carry the same one, so the occlusion test below is evaluated on
    /// the line itself and cuts the ribbon straight across rather than
    /// diagonally through it.
    float3 worldPosition;
    /// How far this point has unfurled towards the plane, 0...1, smoothed. The
    /// sphere test stops applying as the sphere stops being one.
    float horizonRelease;
};

/// Coverage of `position` against the body of the globe: 1 where the line of
/// sight reaches it, 0 where the planet is in the way, with a narrow ramp in
/// between.
///
/// The point is hidden exactly when the segment eye->point passes within the
/// radius of the center, so the test is the distance from the center to that
/// segment. The `t` bounds matter: a point in front of the planet has its
/// closest approach beyond itself (t >= 1), which is what separates "the sphere
/// is between us" from "the sphere is behind the point".
///
/// A plane test through the tangent circle would be cheaper and is exact for
/// points ON the sphere, but the shadow a sphere casts is a cone, not a half
/// space: an arc lifted above the far side leaves that cone while still lying
/// behind the plane, and a plane test would wrongly cut it. Altitude therefore
/// needs no special case here, the sample buffer already holds the lifted
/// position and the segment either clears the planet or it does not.
///
/// Testing the sphere rather than the depth buffer is what makes this
/// independent of how finely the surface is tessellated, whether its tiles have
/// arrived, and whether the polar caps wrote depth.
static inline float routeGlobeClearance(float3 position, constant Camera& camera, constant Globe& globe) {
    float radius = max(globe.radius, 1e-6);
    float3 globeCenter = float3(0.0, 0.0, -globe.radius);
    float3 toPosition = position - camera.eye;
    float lengthSquared = dot(toPosition, toPosition);
    if (lengthSquared <= 0.0) {
        return 1.0;
    }

    float3 centerToEye = camera.eye - globeCenter;
    float closestFraction = -dot(centerToEye, toPosition) / lengthSquared;
    if (closestFraction <= 0.0 || closestFraction >= 1.0) {
        // The nearest approach lies outside the segment: the planet is behind
        // the eye or behind the point, and neither blocks the view.
        return 1.0;
    }

    float3 closest = centerToEye + toPosition * closestFraction;
    return smoothstep(0.0, kRouteHorizonBand, length(closest) / radius - 1.0);
}

vertex RouteVertexOut routeVertexShader(uint vid [[vertex_id]],
                                        const device float4* samples [[buffer(0)]],
                                        constant Camera& camera [[buffer(1)]],
                                        constant RouteUniform& route [[buffer(2)]],
                                        const device float* screenLengths [[buffer(3)]],
                                        constant Globe& globe [[buffer(4)]]) {
    uint last = route.sampleCount > 0u ? route.sampleCount - 1u : 0u;
    uint index = min(vid >> 1, last);
    float side = (vid & 1u) == 0u ? 1.0 : -1.0;
    uint previousIndex = index == 0u ? 0u : index - 1u;
    uint nextIndex = index >= last ? last : index + 1u;

    RouteVertexOut out;
    out.offsetPx = side * (route.halfWidthPx + kRouteFeatherPx);
    out.arcPx = screenLengths[index];
    out.worldPosition = samples[index].xyz;
    // Mirror of GeoScreenProjectionMath.globeVisibility: a point that has
    // already unfurled towards the plane is no longer on a sphere, so the
    // sphere test is released as its local phase advances.
    float3 fromCenter = samples[index].xyz - float3(0.0, 0.0, -globe.radius);
    float frontDot = fromCenter.z / max(length(fromCenter), 1e-6);
    out.horizonRelease = smoothstep(0.0, 0.95,
                                    globeTransitionLocalPhase(globe.transition, frontDot));

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

// Coverage math stays float: dash arclengths reach thousands of pixels and
// the clearance runs on world positions. Only the final color is half.
fragment half4 routeFragmentShader(RouteVertexOut in [[stage_in]],
                                   constant RouteUniform& route [[buffer(0)]],
                                   constant Camera& camera [[buffer(1)]],
                                   constant Globe& globe [[buffer(2)]]) {
    float distancePx = route.halfWidthPx - abs(in.offsetPx);
    float coverage = smoothstep(-0.5, 0.5, distancePx);
    coverage *= routeDashCoverage(in.arcPx, route.dashPx, route.gapPx);
    // Per fragment rather than per vertex: the clearance is not linear in the
    // position, and the cut has to land where the limb is, not at the nearest
    // tessellation step.
    coverage *= max(routeGlobeClearance(in.worldPosition, camera, globe), in.horizonRelease);
    return half4(half3(route.color.rgb), half(route.color.a * coverage));
}
