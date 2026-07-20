// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AtlasSampling.h
//  ImmersiveMap
//
//  Общее ядро семплинга атласа тайлов для глобусного и плоского путей.
//  Здесь собраны решения, выстраданные отладкой швов (см. историю в
//  Globe.metal): явный LOD вместо аппаратного, инсет кромки слота ровно в
//  полтекселя уровня ceil(lod) и допуск покрытия, масштабируемый экранной
//  производной. Менять эти формулы только синхронно для обоих путей.

#include <metal_stdlib>
using namespace metal;

#ifndef ATLAS_SAMPLING
#define ATLAS_SAMPLING

/// Максимальный mip-уровень страниц атласа; синхронизирован с
/// `TileAtlasTexture.pageMipLevelCount` (уровни 0..6).
constant float kAtlasMaxMipLevel = 6.0;

struct AtlasTileBounds {
    float uMin;
    float uMax;
    float vMin;
    float vMax;
};

/// Границы слота тайла в UV страницы из данных размещения (`TileData`).
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
    /// Клампнутые координаты выборки (инсет от кромки слота).
    float2 uv;
    /// Явный LOD для `sample(..., level(lod))`.
    float lod;
    /// Фрагмент за пределами допуска покрытия тайла - дискардить.
    bool outsideCoverage;
};

/// Полный расчёт координат выборки атласа для фрагмента.
///
/// - Допуск покрытия: интерполяция и MSAA у кромки дро-колла выступают за
///   границы тайла примерно на пиксель; при сильной минификации пиксель - это
///   десятки текселей, поэтому допуск не меньше ~полутора экранных пикселей
///   в UV-единицах (константа в текселях рассыпала дальние швы в точки).
/// - LOD задаётся явно: уровни выборки известны точно (floor/ceil), и инсет
///   в полтекселя уровня ceil - минимальный, при котором трилинейный фетч
///   гарантированно не дотягивается до соседнего слота.
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
