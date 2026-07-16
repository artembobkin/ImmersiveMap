// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Разрешает способ отрисовки выдавленных зданий на кадр из режима, альфы и
/// зума камеры. Единая точка решения для планировщика пассов (нужен ли
/// offscreen building image) и subsystem'ы зданий (каким путём и с какой
/// альфой рисовать) - оба обязаны видеть один и тот же путь в кадре.
enum BuildingExtrusionPathResolver {
    enum Path: Equatable {
        /// Непрозрачная геометрия прямо в world-пасс.
        case solid
        /// Непрозрачная геометрия в offscreen building image, который
        /// world-пасс накладывает на карту с этой альфой.
        case composited(alpha: Float)
    }

    static func resolve(style: ImmersiveMapSettings.StyleSettings, zoom: Double) -> Path {
        switch style.buildingExtrusionMode {
        case .solid:
            return .solid
        case .translucent:
            return .composited(alpha: style.buildingExtrusionAlpha)
        case .solidAtHighZoom(let startZoom, let endZoom):
            let span = max(endZoom - startZoom, Double.leastNonzeroMagnitude)
            let progress = min(max((zoom - startZoom) / span, 0.0), 1.0)
            // Композит с альфой 1.0 визуально совпадает с прямым solid-рендером,
            // поэтому по завершении перехода переключаемся на прямой путь и
            // перестаём платить за offscreen-пасс - без скачка картинки.
            guard progress < 1.0 else {
                return .solid
            }
            let alpha = style.buildingExtrusionAlpha + (1.0 - style.buildingExtrusionAlpha) * Float(progress)
            return .composited(alpha: alpha)
        }
    }
}
