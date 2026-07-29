// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import SwiftUI
import simd

/// Чистая математика раскладки hosting-вью маркеров: конверсия
/// drawable-пикселей проекции в поинты view и позиционирование по якорю.
enum MarkerOverlayLayoutMath {
    /// Ниже этой alpha маркер у горизонта глобуса считается неинтерактивным.
    /// Семантика как у `AvatarVisibilityFadeStateStore.activeAlphaThreshold`:
    /// любой видимый маркер интерактивен.
    static let interactionAlphaThreshold: CGFloat = 0.0001

    /// Проекция отдаёт drawable-пиксели с origin снизу слева и y вверх,
    /// view-слой живёт в поинтах с origin сверху слева (NSView flipped):
    /// x = px / scale, y = (drawSize.height - py) / scale.
    /// Инверсия конверсии из `ImmersiveMapSelectionHandler.avatarHitTarget`.
    static func pointFromPixel(_ positionPx: SIMD2<Float>,
                               drawSize: CGSize,
                               contentsScale: CGFloat) -> CGPoint {
        guard contentsScale > 0 else {
            return .zero
        }
        return CGPoint(x: CGFloat(positionPx.x) / contentsScale,
                       y: (drawSize.height - CGFloat(positionPx.y)) / contentsScale)
    }

    /// Кадрирует маркер так, чтобы точка `anchor` его bounds попала в
    /// спроецированную точку: origin = point - anchor * size.
    static func frame(anchorPoint: CGPoint,
                      size: CGSize,
                      anchor: UnitPoint) -> CGRect {
        CGRect(x: anchorPoint.x - size.width * anchor.x,
               y: anchorPoint.y - size.height * anchor.y,
               width: size.width,
               height: size.height)
    }
}
