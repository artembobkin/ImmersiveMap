// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RouteShield.metal
//  ImmersiveMap
//

#include <metal_stdlib>
using namespace metal;
#include "../Shared/LabelTextCommon.h"

// The plate behind a route number, drawn from its distance field. The quad
// is placed by `poiSpriteVertex` like a POI disc: its `uv` carries the
// plate's size in layout points and its `spriteUV` the corner, so the
// distances below are in points and the antialiasing reads the screen's
// own rate of change of them, sharp at every scale. Layout space is y up.

struct RouteShieldStyle {
    float4 fillColor;
    float4 borderColor;
    float4 headerColor;
    float borderWidthPoints;
    float cornerRadiusPoints;
    float headerFraction;
    uint shape;
};

// `RouteShieldAppearance.Shape`: 0 is the rectangle, the default branch.
constant uint kRouteShieldCapsule = 1;
constant uint kRouteShieldEscutcheon = 2;

static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float r = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// A heraldic shield: the box down to where the sides start to curve, and
// below that the lens two circles cut, one through each side, meeting in
// a point at the bottom. Each circle is centred on the far side of the
// axis, so the two arcs leave the straight sides tangentially.
static float escutcheonDistance(float2 p, float2 halfSize, float radius) {
    float box = roundedBoxDistance(p, halfSize, radius);
    float depth = min(1.15 * halfSize.x, 1.6 * halfSize.y);
    float shoulder = -halfSize.y + depth;
    if (p.y >= shoulder) {
        return box;
    }
    float centreOffset = max((depth * depth - halfSize.x * halfSize.x) / (2.0 * halfSize.x), 0.0);
    float arcRadius = halfSize.x + centreOffset;
    float left = length(p - float2(-centreOffset, shoulder)) - arcRadius;
    float right = length(p - float2(centreOffset, shoulder)) - arcRadius;
    return max(box, max(left, right));
}

fragment half4 routeShieldFragment(VertexOut in [[stage_in]],
                                   constant RouteShieldStyle& style [[buffer(0)]]) {
    float2 size = in.uv;
    float2 halfSize = size * 0.5;
    float2 p = (in.spriteUV - 0.5) * size;

    float distance;
    if (style.shape == kRouteShieldCapsule) {
        distance = roundedBoxDistance(p, halfSize, min(halfSize.x, halfSize.y));
    } else if (style.shape == kRouteShieldEscutcheon) {
        distance = escutcheonDistance(p, halfSize, style.cornerRadiusPoints);
    } else {
        distance = roundedBoxDistance(p, halfSize, style.cornerRadiusPoints);
    }

    float aa = max(fwidth(distance), 1.0e-4);
    float coverage = saturate(0.5 - distance / aa);
    float inside = style.borderWidthPoints > 0.0
        ? saturate(0.5 - (distance + style.borderWidthPoints) / aa)
        : 1.0;

    float3 body = style.fillColor.rgb;
    if (style.headerFraction > 0.0) {
        float headerEdge = halfSize.y - size.y * style.headerFraction;
        float headerAA = max(fwidth(p.y), 1.0e-4);
        float header = saturate(0.5 + (p.y - headerEdge) / headerAA);
        body = mix(body, style.headerColor.rgb, header);
    }
    float3 color = mix(style.borderColor.rgb, body, inside);
    return half4(half3(color), half(coverage * in.alpha));
}
