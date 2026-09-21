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

    /// The bits the priority lives in (it is 17 at most): every tile pass
    /// reads and writes the stencil through this mask, so the flags above
    /// stay out of its way.
    static let priorityMask: UInt32 = 0x1F

    /// The road sheet's bit: raised by the first fragment of a road group's
    /// colour stage to land on a pixel and failing every later one, so a
    /// pixel of the sheet is blended once. The group's depth stage clears
    /// it under the group's geometry before the colour stage reads it. See
    /// the road sheet in Tile.metal.
    static let roadSheetBit: UInt32 = 0x20

    /// The flat map's standing surfaces (buildings, scene models) raise this
    /// bit as they draw, on top of whatever priority mark is under them,
    /// and the horizon's ground-side draw fails where it is set: the haze
    /// is decided from the view ray as if every painted pixel were the
    /// ground, and a wall crossing the horizon row would otherwise take the
    /// far ground's haze at that row. A building keeps its own colour and
    /// the ground beside it is veiled.
    static let surfaceMaskBit: UInt32 = 0x80
}
