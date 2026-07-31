// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Cacheable trigonometry of a geocoordinate projection: sin/cos/log are computed
/// once when the coordinate changes, so the per-frame point projection stays
/// linear algebra (no per-point trigonometry per frame).
struct GeoProjectionBasis: Equatable, Sendable {
    /// Unit vector of the point on the sphere in the globe formula's frame
    /// (before the pan rotation): (cosLat*sinLon, sinLat, cosLat*cosLon).
    let sphereUnit: SIMD3<Float>
    /// (lon + pi) / 2pi, normalized X of the world unwrap.
    let normalizedWorldX: Double
    /// Normalized Mercator Y of the latitude.
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
