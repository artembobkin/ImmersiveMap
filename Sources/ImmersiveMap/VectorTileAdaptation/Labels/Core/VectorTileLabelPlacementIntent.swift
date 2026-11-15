// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

enum VectorTileLabelCollisionShape: Equatable {
    case rect
}

enum VectorTileLabelAnchorMode: Equatable {
    case centered
}

struct VectorTileLabelPlacementIntent: Equatable {
    let collisionPaddingPx: Float
    let collisionShape: VectorTileLabelCollisionShape
    let anchorMode: VectorTileLabelAnchorMode
    let screenOffsetPx: SIMD2<Float>

    static let centered = VectorTileLabelPlacementIntent(collisionPaddingPx: 0,
                                                         collisionShape: .rect,
                                                         anchorMode: .centered,
                                                         screenOffsetPx: .zero)
}
