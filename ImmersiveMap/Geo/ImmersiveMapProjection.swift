// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  ImmersiveMapProjection.swift
//  ImmersiveMap
//

import simd

enum ImmersiveMapProjection {
    static let maxMercatorLatitude = 2.0 * atan(exp(Double.pi)) - (Double.pi * 0.5)

    static func wrapNormalizedWorldX(_ x: Double) -> Double {
        var wrapped = x.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 {
            wrapped += 1.0
        }
        return wrapped
    }

    static func clampNormalizedWorldY(_ y: Double) -> Double {
        min(max(0.0, y), 1.0)
    }

    static func worldMercator(latitude: Double,
                              longitude: Double) -> SIMD2<Double> {
        let clampedLatitude = min(max(-maxMercatorLatitude, latitude), maxMercatorLatitude)
        let x = wrapNormalizedWorldX((longitude + Double.pi) / (2.0 * Double.pi))
        let yMercator = yMercatorNormalized(latitude: clampedLatitude)
        let y = clampNormalizedWorldY((1.0 - yMercator) * 0.5)
        return SIMD2<Double>(x, y)
    }

    static func latitude(fromNormalizedWorldY y: Double) -> Double {
        let clampedY = clampNormalizedWorldY(y)
        let mercatorY = (1.0 - 2.0 * clampedY) * Double.pi
        return 2.0 * atan(exp(mercatorY)) - (Double.pi * 0.5)
    }

    static func longitude(fromNormalizedWorldX x: Double) -> Double {
        wrapNormalizedWorldX(x) * (2.0 * Double.pi) - Double.pi
    }

    static func flatPan(fromCenterWorldMercator centerWorldMercator: SIMD2<Double>) -> SIMD2<Double> {
        let centerX = wrapNormalizedWorldX(centerWorldMercator.x)
        let centerY = clampNormalizedWorldY(centerWorldMercator.y)
        return SIMD2<Double>(1.0 - 2.0 * centerX,
                             1.0 - 2.0 * centerY)
    }

    static func globePan(fromCenterWorldMercator centerWorldMercator: SIMD2<Double>) -> SIMD2<Double> {
        let centerX = wrapNormalizedWorldX(centerWorldMercator.x)
        let latitude = latitude(fromNormalizedWorldY: centerWorldMercator.y)
        let normalizedLatitude = latitude / maxMercatorLatitude
        return SIMD2<Double>(1.0 - 2.0 * centerX,
                             min(max(normalizedLatitude, -1.0), 1.0))
    }

    static func centerWorldMercator(fromFlatPan flatPan: SIMD2<Double>) -> SIMD2<Double> {
        let x = wrapNormalizedWorldX((1.0 - flatPan.x) * 0.5)
        let y = clampNormalizedWorldY((1.0 - flatPan.y) * 0.5)
        return SIMD2<Double>(x, y)
    }

    static func centerWorldMercator(fromGlobePan globePan: SIMD2<Double>) -> SIMD2<Double> {
        let longitude = -globePan.x * Double.pi
        let latitude = min(max(globePan.y, -1.0), 1.0) * maxMercatorLatitude
        return worldMercator(latitude: latitude, longitude: longitude)
    }

    /// Returns tile origin (`x`, `y`) and size in flat render-local space.
    /// Coordinates are view-relative: frame-local render pan and wrapped world `loop` are already applied.
    static func flatTileOriginAndSize(x: Int,
                                      y: Int,
                                      z: Int,
                                      loop: Int8,
                                      flatRenderPan: SIMD2<Double>,
                                      renderMapSize: Double) -> SIMD3<Float> {
        let tilesCount = 1 << z
        let tileSize = renderMapSize / Double(tilesCount)
        let halfRenderMapSize = renderMapSize * 0.5
        let originX = Double(x) * tileSize - halfRenderMapSize + flatRenderPan.x * halfRenderMapSize + Double(loop) * renderMapSize
        let originY = Double(tilesCount - y - 1) * tileSize - halfRenderMapSize - flatRenderPan.y * halfRenderMapSize
        return SIMD3<Float>(Float(originX), Float(originY), Float(tileSize))
    }

    /// Returns flat WebMercator coordinates in frame-local render space.
    /// Result is relative to the current flat render view, not an absolute semantic world position.
    static func flatWorldPosition(latitude: Double,
                                  longitude: Double,
                                  flatRenderPan: SIMD2<Double>,
                                  renderMapSize: Double) -> SIMD2<Float> {
        let halfRenderMapSize = renderMapSize * 0.5
        let xNorm = (longitude + Double.pi) / (2.0 * Double.pi)
        let xWorld = wrap(value: xNorm * renderMapSize - halfRenderMapSize + flatRenderPan.x * halfRenderMapSize,
                          size: renderMapSize)
        let yNorm = yMercatorNormalized(latitude: latitude)
        let yWorld = (yNorm - flatRenderPan.y) * halfRenderMapSize
        return SIMD2<Float>(Float(xWorld), Float(yWorld))
    }

    /// Converts latitude in radians to normalized WebMercator Y (`[-1, 1]`),
    /// with pole clamping to keep the value finite.
    static func yMercatorNormalized(latitude: Double) -> Double {
        let sinLatitude = sin(latitude)
        let maxSinLatitude = tanh(Double.pi)
        let clamped = max(-maxSinLatitude, min(maxSinLatitude, sinLatitude))
        let yMercator = 0.5 * log((1.0 + clamped) / (1.0 - clamped))
        return yMercator / Double.pi
    }

    static func wrap(value: Double, size: Double) -> Double {
        return value - size * floor((value + size * 0.5) / size)
    }
}
