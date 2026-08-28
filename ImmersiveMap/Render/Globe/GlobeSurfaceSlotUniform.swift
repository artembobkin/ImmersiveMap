// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The slot one placeholder fill of the globe surface covers; mirrors the
/// `Tile` struct the globe vertex shader reads at buffer 3 (Globe.metal).
struct GlobeSurfaceSlotUniform {
    var tile: SIMD3<Int32>

    init(_ tile: Tile) {
        self.tile = SIMD3<Int32>(Int32(tile.x), Int32(tile.y), Int32(tile.z))
    }
}
