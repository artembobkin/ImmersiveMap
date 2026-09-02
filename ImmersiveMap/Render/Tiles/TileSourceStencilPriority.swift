// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The stencil reference of a tile source: its zoom, shifted off the
/// cleared value. The ground's owner passes write it wherever they paint
/// and every tile pass tests `greaterEqual` against it, so a coarser
/// substitute's overflow fails wherever a finer tile painted, a tile's own
/// later layers pass over its own mark, and same-zoom neighbours keep
/// painting their stitching margins over each other exactly as before.
/// One mechanism for the sphere and the flat map; the depth buffer keeps
/// its own job (layer ranks on the sphere, real building geometry on the
/// plane).
enum TileSourceStencilPriority {
    /// 1...17: zoom clamped to the tile scheme's range, plus one so the
    /// cleared stencil (0) reads as "nobody painted".
    static func reference(sourceZoom: Int) -> UInt32 {
        UInt32(min(max(sourceZoom, 0), 16) + 1)
    }
}
