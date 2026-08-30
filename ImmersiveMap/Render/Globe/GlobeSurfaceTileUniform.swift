// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-draw tile identity of the sphere tile pipeline; the layout mirrors
/// `GlobeSurfaceTile` in TileSphere.metal (pinned by
/// `GlobeVectorSurfaceUniformLayoutTests`).
struct GlobeSurfaceTileUniform {
    /// The source tile the vertices are local to.
    var tile: SIMD3<Int32>

    init(tile: Tile) {
        self.tile = SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
    }
}
