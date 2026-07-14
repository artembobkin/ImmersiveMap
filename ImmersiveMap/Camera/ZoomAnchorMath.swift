// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd

/// Считает компенсацию центра карты для anchored zoom: мировая точка под курсором
/// (точкой жеста) остаётся на своём месте на экране, то есть камера подтягивается
/// к курсору при приближении и отдаляется от него при отдалении.
///
/// Экранная модель повторяет рендер: перспективная камера с fov π/4 на дистанции
/// `1 - 0.5·frac(zoom)` и мир размером `2π·globeRadiusScale·2^floor(zoom)`
/// (`RenderCameraPoseResolver` + `PresentationStateResolver`). В глобусной фазе
/// сфера вблизи центра экрана локально сжимает мир на `cos(latitude)`, поэтому
/// используется линейное приближение: у краёв глобуса якорение приближённое.
/// Наклон камеры (pitch) в модели не учитывается.
enum ZoomAnchorMath {
    struct Input {
        /// Точка жеста в координатах view (top-left origin, points).
        let anchorPoint: CGPoint
        /// Размер view в points.
        let viewportSize: CGSize
        let centerWorldMercator: SIMD2<Double>
        let zoomBefore: Double
        let zoomAfter: Double
        let bearing: Float
        /// Фаза глобус→плоскость до и после зума: 0 — глобус, 1 — плоскость.
        let transitionBefore: Float
        let transitionAfter: Float
        let globeRadiusScale: Double
        /// Доля компенсации: 0 — зум в центр экрана, 1 — точка под курсором неподвижна.
        let anchorFactor: Double
    }

    /// tan(fov/2) для fov π/4 из `RenderCamera.recalculateProjection`.
    private static let halfFovTangent = tan(Double.pi / 8.0)

    static func compensatedCenterWorldMercator(_ input: Input) -> SIMD2<Double> {
        let width = Double(input.viewportSize.width)
        let height = Double(input.viewportSize.height)
        let center = input.centerWorldMercator
        guard width > 0,
              height > 0,
              input.anchorFactor > 0,
              input.zoomBefore != input.zoomAfter else {
            return center
        }

        // Смещение якоря от центра экрана; экранная ось Y (вниз) переводится в
        // рендерную (вверх).
        let anchorFromCenter = SIMD2<Double>(Double(input.anchorPoint.x) - width * 0.5,
                                             height * 0.5 - Double(input.anchorPoint.y))
        guard anchorFromCenter != .zero else {
            return center
        }

        // Экранные оси → мировые рендер-оси: камера повёрнута на bearing вокруг Z,
        // мировой вектор под экранным смещением p равен R(bearing)·p.
        let bearing = Double(input.bearing)
        let cosBearing = cos(bearing)
        let sinBearing = sin(bearing)
        let worldDirection = SIMD2<Double>(anchorFromCenter.x * cosBearing - anchorFromCenter.y * sinBearing,
                                           anchorFromCenter.x * sinBearing + anchorFromCenter.y * cosBearing)

        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: center.y)
        let unitsPerPointBefore = normalizedWorldUnitsPerPoint(zoom: input.zoomBefore,
                                                               transition: input.transitionBefore,
                                                               latitude: latitude,
                                                               viewportHeight: height,
                                                               globeRadiusScale: input.globeRadiusScale)
        let unitsPerPointAfter = normalizedWorldUnitsPerPoint(zoom: input.zoomAfter,
                                                              transition: input.transitionAfter,
                                                              latitude: latitude,
                                                              viewportHeight: height,
                                                              globeRadiusScale: input.globeRadiusScale)
        let unitsPerPointDelta = unitsPerPointBefore - unitsPerPointAfter
        guard unitsPerPointDelta.isFinite, unitsPerPointDelta != 0 else {
            return center
        }

        // Мировая точка под якорем: w = c + (unitsPerPoint·worldDirection.x,
        // -unitsPerPoint·worldDirection.y); нормализованный мировой Y растёт к югу,
        // рендерный Y — к северу. Требование w(before) = w(after) даёт сдвиг центра.
        let shift = unitsPerPointDelta * input.anchorFactor
        let compensated = SIMD2<Double>(center.x + worldDirection.x * shift,
                                        center.y - worldDirection.y * shift)
        return SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(compensated.x),
                             ImmersiveMapProjection.clampNormalizedWorldY(compensated.y))
    }

    /// Normalized-world единиц в одном screen point по горизонтали центра экрана:
    /// q(z) = 2·d(z)·tan(fov/2) / (H·mapSize(z)·surfaceScale).
    /// `surfaceScale` интерполирует локальный масштаб поверхности между сферой
    /// (cos(lat)) и плоскостью (1) по фазе перехода.
    private static func normalizedWorldUnitsPerPoint(zoom: Double,
                                                     transition: Float,
                                                     latitude: Double,
                                                     viewportHeight: Double,
                                                     globeRadiusScale: Double) -> Double {
        let cameraDistance = 1.0 - 0.5 * zoom.truncatingRemainder(dividingBy: 1.0)
        let renderMapSize = 2.0 * Double.pi * globeRadiusScale * pow(2.0, floor(zoom))
        let flatness = Double(min(max(transition, 0.0), 1.0))
        let surfaceScale = flatness + (1.0 - flatness) * max(cos(latitude), 1e-6)
        return (2.0 * cameraDistance * halfFovTangent) / (viewportHeight * renderMapSize * surfaceScale)
    }
}
