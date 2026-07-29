// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Экранная позиция одного маркера в drawable-пикселях (origin снизу слева,
/// y вверх). `visibilityAlpha` несёт мягкий фейд горизонта глобуса.
struct MarkerProjectedEntry: Equatable, Sendable {
    let id: UInt64
    let positionPx: SIMD2<Float>
    let visibilityAlpha: Float
}

/// Пер-кадровый снапшот проекции маркеров. В `entries` только видимые
/// маркеры: отсутствие id означает «скрыть view».
struct MarkerProjectionSnapshot: Equatable, Sendable {
    static let empty = MarkerProjectionSnapshot(frameIndex: 0,
                                                drawSize: .zero,
                                                entries: [])

    let frameIndex: UInt64
    let drawSize: CGSize
    let entries: [MarkerProjectedEntry]
}
