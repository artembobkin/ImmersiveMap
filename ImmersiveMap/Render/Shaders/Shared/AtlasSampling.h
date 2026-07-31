// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AtlasSampling.h
//  ImmersiveMap
//
//  Shared tile-atlas sampling core for the globe and flat paths.
//  This collects the decisions hard-won while debugging seams (see the history
//  in Globe.metal): explicit LOD instead of hardware LOD, a slot-edge inset of
//  exactly half a texel of the ceil(lod) level, and a coverage tolerance scaled
//  by the screen derivative. Change these formulas only in sync for both paths.

#include <metal_stdlib>
using namespace metal;

#ifndef ATLAS_SAMPLING
#define ATLAS_SAMPLING

/// Maximum mip level of the atlas pages; kept in sync with
/// `TileAtlasTexture.pageMipLevelCount` (levels 0..6).
constant float kAtlasMaxMipLevel = 6.0;

struct AtlasTileBounds {
    float uMin;
    float uMax;
    float vMin;
    float vMax;
};

/// Tile slot bounds in page UV from the placement data (`TileData`).
static inline AtlasTileBounds atlasTileBounds(float posU,
                                              float posV,
                                              float lastPos,
                                              float uvSize) {
    AtlasTileBounds bounds;
    bounds.uMin = posU * uvSize;
    bounds.uMax = bounds.uMin + uvSize;
    bounds.vMin = (lastPos - posV) * uvSize;
    bounds.vMax = 1.0 - posV * uvSize;
    return bounds;
}

struct AtlasSampleCoords {
    /// Clamped sampling coordinates (inset from the slot edge).
    float2 uv;
    /// Explicit LOD for `sample(..., level(lod))`.
    float lod;
    /// Fragment outside the tile coverage tolerance, discard it.
    bool outsideCoverage;
};

/// Full atlas sample coordinate computation for a fragment.
///
/// - Coverage tolerance: interpolation and MSAA at the draw-call edge overshoot
///   the tile bounds by about a pixel; under strong minification a pixel is
///   tens of texels, so the tolerance is at least ~1.5 screen pixels in UV
///   units (a constant in texels crumbled distant seams into dots).
/// - LOD is set explicitly: the sampled levels are known exactly (floor/ceil),
///   and the half-texel inset of the ceil level is the minimum at which a
///   trilinear fetch is guaranteed not to reach into the neighboring slot.
static inline AtlasSampleCoords atlasSampleCoords(float2 uv,
                                                  AtlasTileBounds bounds,
                                                  float halfTexel) {
    float pageTexels = 0.5 / halfTexel;
    float2 uvTexels = uv * pageTexels;
    float2 lodDx = dfdx(uvTexels);
    float2 lodDy = dfdy(uvTexels);
    float texelsPerPixel = sqrt(max(max(length_squared(lodDx), length_squared(lodDy)), 1e-12));

    float coverageTolerance = max(halfTexel * 8.0, 1.5 * texelsPerPixel / pageTexels);
    bool outsideCoverage = uv.y > bounds.vMax + coverageTolerance
        || uv.y < bounds.vMin - coverageTolerance
        || uv.x > bounds.uMax + coverageTolerance
        || uv.x < bounds.uMin - coverageTolerance;

    float clampedLod = clamp(log2(texelsPerPixel), 0.0, kAtlasMaxMipLevel);
    float sampleInset = halfTexel * exp2(ceil(clampedLod));

    AtlasSampleCoords coords;
    coords.uv = float2(max(bounds.uMin + sampleInset, min(bounds.uMax - sampleInset, uv.x)),
                       max(bounds.vMin + sampleInset, min(bounds.vMax - sampleInset, uv.y)));
    coords.lod = clampedLod;
    coords.outsideCoverage = outsideCoverage;
    return coords;
}

#endif
