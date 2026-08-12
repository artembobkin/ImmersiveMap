// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// One ground/road geometry vertex as the tile shaders consume it. The memory
/// layout is a binding contract shared by three parties: `TilePipeline`'s
/// vertex descriptor (attribute offsets and stride), the arena image format
/// (span strides, see `TileArenaImageMath`), and the parser that emits the
/// vertices. Changing the layout is therefore a shader change and a
/// prepared-cache format change (bump `PreparedTileDiskCaching.preparedFormatVersion`).
struct TileVertexIn: Sendable {
    let position: SIMD2<Int16>
    let styleIndex: UInt8
    let _padding0: UInt8 = 0
    let _padding1: UInt8 = 0
    let _padding2: UInt8 = 0
}
