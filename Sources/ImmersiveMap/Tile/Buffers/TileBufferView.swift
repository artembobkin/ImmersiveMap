// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// A sub-range of a tile's single backing allocation: everything a draw call
/// needs to bind it, so consumers never reach back to the arena. The layout
/// of the backing allocation is the canonical `TileArenaImageMath` plan.
struct TileBufferView {
    let buffer: MTLBuffer
    let offset: Int
    /// Element count of the typed content (vertices, indices, styles...).
    let count: Int
}
