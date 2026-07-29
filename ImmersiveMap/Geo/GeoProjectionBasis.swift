// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Кешируемая тригонометрия проекции геокоординаты: sin/cos/log считаются
/// один раз при смене координаты, пер-кадровая проекция точки остаётся
/// линейной алгеброй (без тригонометрии на точку на кадр).
struct GeoProjectionBasis: Equatable, Sendable {
    /// Единичный вектор точки на сфере в системе формулы глобуса
    /// (до вращения панорамы): (cosLat*sinLon, sinLat, cosLat*cosLon).
    let sphereUnit: SIMD3<Float>
    /// (lon + pi) / 2pi, нормализованный X мировой развёртки.
    let normalizedWorldX: Double
    /// Нормализованный меркаторный Y широты.
    let mercatorYNormalized: Double

    init(coordinate: GeoCoordinate) {
        self.init(latitudeRadians: coordinate.latitude * .pi / 180.0,
                  longitudeRadians: coordinate.longitude * .pi / 180.0)
    }

    init(latitudeRadians: Double, longitudeRadians: Double) {
        let cosLatitude = cos(latitudeRadians)
        sphereUnit = SIMD3<Float>(Float(cosLatitude * sin(longitudeRadians)),
                                  Float(sin(latitudeRadians)),
                                  Float(cosLatitude * cos(longitudeRadians)))
        normalizedWorldX = (longitudeRadians + .pi) / (2.0 * .pi)
        mercatorYNormalized = ImmersiveMapProjection.yMercatorNormalized(latitude: latitudeRadians)
    }
}
