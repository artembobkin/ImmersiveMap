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
    /// Analytic line antialiasing, packed into what used to be padding.
    /// `lineDistance` is the signed distance from the line's centerline,
    /// normalized so the extruded geometry rim is ±`Int16.max`;
    /// `lineEdgeThreshold` is where the visible edge sits inside that field
    /// (the styled half-width over the extruded half-width, as a 0...255
    /// fraction). Zero threshold marks non-line geometry: the fragment shader
    /// skips coverage for it entirely, so plain polygons render as before.
    let lineEdgeThreshold: UInt8
    let lineDistance: Int16

    init(position: SIMD2<Int16>,
         styleIndex: UInt8,
         lineEdgeThreshold: UInt8 = 0,
         lineDistance: Int16 = 0) {
        self.position = position
        self.styleIndex = styleIndex
        self.lineEdgeThreshold = lineEdgeThreshold
        self.lineDistance = lineDistance
    }
}
