// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct LabelPlacementMeta {
    let key: UInt64
    let sortKey: Int
    let collisionPriority: Int
    let labelSizePx: SIMD2<Float>
    /// Minimum CAMERA zoom at which the label is visible. 0 = always visible.
    /// Resolved at runtime (via `frameContext.zoom`), not via `tile.z`, so it
    /// also works under overzoom (when tile.z is capped at the source's maxzoom).
    let minCameraZoom: Float
}
