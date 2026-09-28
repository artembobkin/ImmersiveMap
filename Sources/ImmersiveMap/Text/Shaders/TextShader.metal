// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;
#include "../../Labels/Shaders/Shared/LabelTextCommon.h"

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct TextStyle {
    float3 textColor;
    // How far the letters are grown past the font's outline, in pixels.
    float fillBiasPx;
    float3 strokeColor;
    float strokeWidthPx;
};

struct TextDistance {
    float msdfPxDist;
    float sdfPxDist;
    float screenPxRange;
};

// The label fragment's colour and its depth. The text draws fill and halo in
// one pass, and neighbouring glyph quads overlap (each quad carries the
// atlas's distance margin), so a later glyph's halo would paint over an
// earlier glyph's fill where the quads meet. The depth orders them: a fill
// fragment writes the nearer of two far-plane depths and a halo fragment the
// farther, under lessEqual with depth write on, so a halo never lands on a
// fill that is already there while a fill still lands on a halo. Both sit
// just short of the far plane, and a fragment with no coverage writes the
// far plane itself, which changes nothing.
struct TextFragmentOut {
    half4 color [[color(0)]];
    float depth [[depth(less)]];
};

constant float kLabelFillDepth = 0.99999976;
constant float kLabelHaloDepth = 0.99999988;

vertex VertexOut textVertex(VertexIn in [[stage_in]],
                            constant float4x4& matrix [[buffer(1)]]
                            ) {
    VertexOut out;
    out.position = matrix * in.position;
    out.uv = in.uv;
    out.alpha = 1.0;
    out.spriteUV = float2(0.0);
    return out;
}

// Px-space distances stay float: screenPxRange comes from uv derivatives that
// shrink below half's normal range on magnified glyphs. The unit-range tail
// (fill/stroke coverage, color mixing) runs in half; the 8-bit target cannot
// see the difference and A-series GPUs execute half at twice the float rate.
static TextDistance computeTextDistance(VertexOut in,
                                        texture2d<half> atlasTexture) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    half4 atlasSample = atlasTexture.sample(textureSampler, in.uv);
    half3 msdf = atlasSample.rgb;
    float sd = float(max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b))) - 0.5;
    float sdf = float(atlasSample.a) - 0.5;
    const float distanceRange = 24.0;
    float2 texSize = float2(atlasTexture.get_width(), atlasTexture.get_height());
    float2 unitRange = float2(distanceRange) / texSize;
    float2 duv = max(fwidth(in.uv), float2(1e-6));
    float2 screenTexSize = 1.0 / duv;
    float screenPxRange = max(0.5 * dot(unitRange, screenTexSize), 1.0);
    TextDistance distance;
    distance.msdfPxDist = sd * screenPxRange;
    distance.sdfPxDist = sdf * screenPxRange;
    distance.screenPxRange = screenPxRange;
    return distance;
}

static TextFragmentOut shadeGlyph(TextDistance distance,
                                  float fillPxDist,
                                  float strokeWidthPx,
                                  constant TextStyle& style,
                                  float vertexAlpha) {
    half fill = half(smoothstep(-0.5, 0.5, fillPxDist));
    half outer = half(smoothstep(-strokeWidthPx - 0.5, -strokeWidthPx + 0.5, distance.sdfPxDist));
    // A style that asks for no halo gets none, exactly: the fill and the outer
    // edge are read from two different distance fields (the MSDF keeps a
    // corner sharp where the plain SDF rounds it), so at zero width their
    // difference is not reliably zero and a hairline of stroke colour can
    // survive around a corner.
    half stroke = strokeWidthPx > 0.0 ? clamp(outer - fill, 0.0h, 1.0h) : 0.0h;

    half coverage = clamp(fill + stroke, 0.0h, 1.0h);
    half alpha = coverage * half(vertexAlpha);
    half3 color = (fill * half3(style.textColor) + stroke * half3(style.strokeColor))
        / max(coverage, 1.0e-4h);
    TextFragmentOut out;
    out.color = half4(color, alpha);
    out.depth = fill > 0.0h ? kLabelFillDepth : (stroke > 0.0h ? kLabelHaloDepth : 1.0);
    return out;
}

fragment TextFragmentOut textFragment(VertexOut in [[stage_in]],
                            texture2d<half> atlasTexture [[texture(0)]],
                            constant TextStyle& style [[buffer(0)]]
                            ) {
    TextDistance distance = computeTextDistance(in, atlasTexture);

    // Point labels sit on textured terrain, so keep the halo narrow enough
    // that large style values cannot fill the glyph quad.
    float maxStrokePx = max(0.5 * distance.screenPxRange - 0.5, 0.0);
    float strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    return shadeGlyph(distance,
                      distance.msdfPxDist + style.fillBiasPx,
                      strokeWidthPx,
                      style,
                      in.alpha);
}

fragment TextFragmentOut roadTextFragment(RoadTextVertexOut roadIn [[stage_in]],
                                texture2d<half> atlasTexture [[texture(0)]],
                                depth2d<float> sceneDepth [[texture(1)]],
                                constant TextStyle& style [[buffer(0)]],
                                constant RoadLabelSceneDepthUniforms& scene [[buffer(1)]]
                                ) {
    // The buildings and the models paint over the road names behind them:
    // a pixel of the name is dropped where the world pass drew something
    // nearer than the glyph's place on the road. The ground's depth is a
    // band at the far plane, so only a building or a model cuts.
    if (scene.enabled != 0) {
        uint2 pixel = uint2(roadIn.position.xy);
        if (pixel.x < sceneDepth.get_width() && pixel.y < sceneDepth.get_height()
            && sceneDepth.read(pixel) < roadIn.anchorDepth) {
            discard_fragment();
        }
    }

    VertexOut in;
    in.position = roadIn.position;
    in.uv = roadIn.uv;
    in.alpha = roadIn.alpha;
    in.spriteUV = roadIn.spriteUV;
    TextDistance distance = computeTextDistance(in, atlasTexture);

    // A road label is rotated along its road, and `fwidth` sums the uv
    // derivatives of both screen axes, so on a glyph turned by 45 degrees it
    // reads the range about 1.4 times too small. The range here comes from
    // the length of the derivatives instead, the same at every angle, and
    // the distances are rescaled to it.
    const float distanceRange = 24.0;
    float2 texSize = float2(atlasTexture.get_width(), atlasTexture.get_height());
    float2 texelsPerPixelX = dfdx(in.uv) * texSize;
    float2 texelsPerPixelY = dfdy(in.uv) * texSize;
    float texelsPerPixel = sqrt(0.5 * (dot(texelsPerPixelX, texelsPerPixelX)
                                       + dot(texelsPerPixelY, texelsPerPixelY)));
    float screenPxRange = max(distanceRange / max(texelsPerPixel, 1e-6), 1.0);
    float rescale = screenPxRange / distance.screenPxRange;
    distance.msdfPxDist *= rescale;
    distance.sdfPxDist *= rescale;
    distance.screenPxRange = screenPxRange;

    // The halo stays inside the distance field's support, half the range
    // past the glyph edge. Beyond it the field is flat at its minimum, and a
    // wider halo covers the whole glyph quad, drawing the label as boxes.
    float maxStrokePx = max(0.5 * distance.screenPxRange - 0.5, 0.0);
    float strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    return shadeGlyph(distance,
                      distance.msdfPxDist + style.fillBiasPx,
                      strokeWidthPx,
                      style,
                      in.alpha);
}
