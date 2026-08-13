// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct LabelPlacementMeta {
    let key: UInt64
    let sortKey: Int
    let collisionPriority: Int
    /// Collision box in layout points. Scaled to device pixels once the frame's
    /// screen scale is known (see `ScreenScale`), which is also the space the
    /// screen positions it is tested against live in.
    let labelSizePoints: SIMD2<Float>
    /// Minimum CAMERA zoom at which the label is visible. 0 = always visible.
    /// Resolved at runtime (via `frameContext.zoom`), not via `tile.z`, so it
    /// also works under overzoom (when tile.z is capped at the source's maxzoom).
    let minCameraZoom: Float
}
