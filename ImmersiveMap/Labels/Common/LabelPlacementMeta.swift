// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct LabelPlacementMeta {
    let key: UInt64
    let sortKey: Int
    let collisionPriority: Int
    let labelSizePx: SIMD2<Float>
    /// Минимальный зум КАМЕРЫ, с которого лейбл виден. 0 = виден всегда.
    /// Решается в рантайме (по `frameContext.zoom`), а не по `tile.z`, поэтому
    /// работает и при overzoom (когда tile.z упёрт в maxzoom источника).
    let minCameraZoom: Float
}
