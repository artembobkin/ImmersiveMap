// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

enum CameraFlightMath {
    static let minimumDuration: TimeInterval = 0.001
    private static let deltaEpsilon = 1e-9
    private static let greatCircleAngleEpsilon = 1e-6

    static func easeInOutCubic(_ progress: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        if clampedProgress < 0.5 {
            return 4 * clampedProgress * clampedProgress * clampedProgress
        }

        let invertedProgress = -2 * clampedProgress + 2
        return 1 - (invertedProgress * invertedProgress * invertedProgress) / 2
    }

    static func shortestWrappedWorldDelta(from start: Double,
                                          to end: Double) -> Double {
        var delta = end - start
        if delta > 0.5 {
            delta -= 1.0
        } else if delta < -0.5 {
            delta += 1.0
        }
        return delta
    }

    static func interpolateWrappedWorldX(from start: Double,
                                         to end: Double,
                                         progress: Double) -> Double {
        ImmersiveMapProjection.wrapNormalizedWorldX(start + shortestWrappedWorldDelta(from: start, to: end) * progress)
    }

    static func shortestBearingDelta(from start: Float,
                                     to end: Float) -> Float {
        let normalizedStart = CameraBearingConstraintResolver.normalized(start)
        let normalizedEnd = CameraBearingConstraintResolver.normalized(end)
        var delta = normalizedEnd - normalizedStart
        if delta > .pi {
            delta -= 2 * .pi
        } else if delta < -.pi {
            delta += 2 * .pi
        }
        return delta
    }

    static func interpolateBearing(from start: Float,
                                   to end: Float,
                                   progress: Double) -> Float {
        let normalizedStart = CameraBearingConstraintResolver.normalized(start)
        let delta = shortestBearingDelta(from: start, to: end)
        return CameraBearingConstraintResolver.normalized(normalizedStart + delta * Float(progress))
    }

    static func hasMeaningfulDelta(from start: ImmersiveMapCameraState,
                                   to end: ImmersiveMapCameraState) -> Bool {
        abs(shortestWrappedWorldDelta(from: start.centerWorldMercator.x, to: end.centerWorldMercator.x)) > deltaEpsilon
            || abs(end.centerWorldMercator.y - start.centerWorldMercator.y) > deltaEpsilon
            || abs(end.zoom - start.zoom) > deltaEpsilon
            || abs(shortestBearingDelta(from: start.bearing, to: end.bearing)) > Float(deltaEpsilon)
            || abs(end.pitch - start.pitch) > Float(deltaEpsilon)
    }

    static func mercatorCenter(from start: SIMD2<Double>,
                               to end: SIMD2<Double>,
                               progress: Double) -> SIMD2<Double> {
        SIMD2<Double>(interpolateWrappedWorldX(from: start.x, to: end.x, progress: progress),
                      start.y + (end.y - start.y) * progress)
    }

    /// Длина маршрута по кратчайшему mercator-пути в нормализованных мировых
    /// координатах (1.0 = полный оборот по x).
    static func mercatorRouteDistance(from start: SIMD2<Double>,
                                      to end: SIMD2<Double>) -> Double {
        let deltaX = shortestWrappedWorldDelta(from: start.x, to: end.x)
        return simd_length(SIMD2<Double>(deltaX, end.y - start.y))
    }

    /// Длина маршрута по большой дуге в тех же единицах: доля экваториальной
    /// окружности (угол дуги / 2π), чтобы быть сопоставимой с mercator-дистанцией.
    static func greatCircleRouteDistance(from start: SIMD2<Double>,
                                         to end: SIMD2<Double>) -> Double {
        let startVector = normalizedCartesian(
            latitudeRadians: ImmersiveMapProjection.latitude(fromNormalizedWorldY: start.y),
            longitudeRadians: ImmersiveMapProjection.longitude(fromNormalizedWorldX: start.x)
        )
        let endVector = normalizedCartesian(
            latitudeRadians: ImmersiveMapProjection.latitude(fromNormalizedWorldY: end.y),
            longitudeRadians: ImmersiveMapProjection.longitude(fromNormalizedWorldX: end.x)
        )
        let dotProduct = min(1.0, max(-1.0, simd_dot(startVector, endVector)))
        return acos(dotProduct) / (2.0 * .pi)
    }

    /// Траектория зума и пана «взлёт, полёт, пикирование» по van Wijk и Nuij
    /// ("Smooth and efficient zooming and panning", 2003). Высота апекса растёт
    /// с дальностью перелёта вплоть до вида глобуса, а скорость пана связана
    /// с высотой: у земли камера ползёт, на апексе покрывает основную дистанцию.
    struct OverviewFlightProfile {
        struct Sample {
            /// Прогресс центра камеры вдоль маршрута в [0, 1].
            let panProgress: Double
            let zoom: Double
        }

        /// Крутизна дуги: чем больше, тем выше апекс. 1.42 - значение из
        /// оригинальной статьи, его же использует Mapbox flyTo.
        private static let rho = 1.42
        private static let distanceEpsilon = 1e-9

        private let startVisibleSpan: Double
        private let routeDistance: Double
        private let startR: Double
        private let totalS: Double
        private let coshStartR: Double
        private let sinhStartR: Double

        /// Возвращает nil для вырожденных перелётов (нет горизонтального
        /// смещения), где траектория совпадает с прямой интерполяцией зума.
        static func make(startZoom: Double,
                         targetZoom: Double,
                         normalizedWorldDistance: Double) -> OverviewFlightProfile? {
            let routeDistance = normalizedWorldDistance
            guard routeDistance.isFinite, routeDistance > distanceEpsilon else {
                return nil
            }

            // Видимая ширина мира w = 2^-zoom: единицы согласованы с мировой
            // дистанцией, константа вьюпорта на форму дуги не влияет.
            let startSpan = pow(2.0, -startZoom)
            let targetSpan = pow(2.0, -targetZoom)
            let rhoSquared = rho * rho
            let spanDelta = targetSpan * targetSpan - startSpan * startSpan
            let arcTerm = rhoSquared * rhoSquared * routeDistance * routeDistance
            let b0 = (spanDelta + arcTerm) / (2.0 * startSpan * rhoSquared * routeDistance)
            let b1 = (spanDelta - arcTerm) / (2.0 * targetSpan * rhoSquared * routeDistance)
            // r(b) = ln(sqrt(b^2 + 1) - b) = -asinh(b), asinh численно стабильнее.
            let startR = -asinh(b0)
            let targetR = -asinh(b1)
            let totalS = (targetR - startR) / rho
            guard totalS.isFinite, totalS > 0 else {
                return nil
            }

            return OverviewFlightProfile(startVisibleSpan: startSpan,
                                         routeDistance: routeDistance,
                                         startR: startR,
                                         totalS: totalS,
                                         coshStartR: cosh(startR),
                                         sinhStartR: sinh(startR))
        }

        func sample(atProgress progress: Double) -> Sample {
            let clampedProgress = min(max(progress, 0), 1)
            let x = Self.rho * clampedProgress * totalS + startR
            let traveled = startVisibleSpan / (Self.rho * Self.rho)
                * (coshStartR * tanh(x) - sinhStartR)
            let visibleSpan = startVisibleSpan * coshStartR / cosh(x)
            return Sample(panProgress: min(max(traveled / routeDistance, 0), 1),
                          zoom: -log2(visibleSpan))
        }
    }

    static func greatCircleCenter(from start: SIMD2<Double>,
                                  to end: SIMD2<Double>,
                                  progress: Double) -> SIMD2<Double>? {
        let startLatitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: start.y)
        let startLongitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: start.x)
        let endLatitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: end.y)
        let endLongitude = ImmersiveMapProjection.longitude(fromNormalizedWorldX: end.x)

        let startVector = normalizedCartesian(latitudeRadians: startLatitude,
                                              longitudeRadians: startLongitude)
        let endVector = normalizedCartesian(latitudeRadians: endLatitude,
                                            longitudeRadians: endLongitude)

        let dotProduct = min(1.0, max(-1.0, simd_dot(startVector, endVector)))
        let angle = acos(dotProduct)
        let interpolatedVector: SIMD3<Double>
        if angle < greatCircleAngleEpsilon {
            interpolatedVector = simd_normalize(startVector + (endVector - startVector) * progress)
        } else if abs(.pi - angle) < greatCircleAngleEpsilon {
            return nil
        } else {
            let sinAngle = sin(angle)
            guard abs(sinAngle) >= greatCircleAngleEpsilon else {
                return nil
            }

            let startWeight = sin((1 - progress) * angle) / sinAngle
            let endWeight = sin(progress * angle) / sinAngle
            interpolatedVector = simd_normalize(startVector * startWeight + endVector * endWeight)
        }

        let latitude = asin(max(-1.0, min(1.0, interpolatedVector.z)))
        let longitude = atan2(interpolatedVector.y, interpolatedVector.x)
        return ImmersiveMapProjection.worldMercator(latitude: latitude,
                                                    longitude: longitude)
    }

    private static func normalizedCartesian(latitudeRadians latitude: Double,
                                            longitudeRadians longitude: Double) -> SIMD3<Double> {
        let cosLatitude = cos(latitude)
        return simd_normalize(
            SIMD3<Double>(cosLatitude * cos(longitude),
                          cosLatitude * sin(longitude),
                          sin(latitude))
        )
    }
}
