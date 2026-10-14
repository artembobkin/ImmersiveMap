// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The stencil reference of a tile source, on either surface: its zoom,
/// shifted off the cleared value. The owner pass (the opaque fills, and a
/// raster tile's texture) writes it wherever it paints, sources drawn
/// finest first, and every later tile pass tests `greaterEqual` against
/// it, so a coarser substitute's overflow fails wherever a finer tile
/// painted, a tile's own later layers pass over its own mark, and
/// same-zoom neighbours keep painting their stitching margins over each
/// other. A source draws at full extent, in every slot it stands in at
/// once, so nothing is cut to a slot on the CPU or in the vertex stage.
/// On the relief a finer tile owns its pixels whatever rises in front of
/// them, so a coarser stand-in's near ridge gives way to a finer tile's
/// far ground along the finer tile's edge: the price of ownership by
/// zoom alone. The flat map packs the ring of a source's slot above its
/// zoom (`FlatTileStencilPacking`), and a prepass marks the rings, so a
/// source also never draws on a ring nearer than its own. The bits above
/// the priority serve both surfaces.
enum TileSourceStencilPriority {
    /// The sphere's reference, 1...17: zoom clamped to the tile scheme's
    /// range, plus one so the cleared stencil (0) reads as "nobody
    /// painted". The flat map's is `FlatTileStencilPacking`.
    static func reference(sourceZoom: Int) -> UInt32 {
        UInt32(min(max(sourceZoom, 0), 16) + 1)
    }

    /// The bits the priority lives in, six: every tile pass reads and
    /// writes the stencil through this mask, so the flags above stay out
    /// of its way.
    static let priorityMask: UInt32 = 0x3F

    /// The ground hole of a scene model that cuts into the ground
    /// (`ImmersiveMapSceneModel.cutsIntoGround`): raised over the model's
    /// outline flattened onto the surface before the model draws, so its
    /// fragments below the surface pass only inside the outline and are
    /// dropped outside it, and lowered again after the model, so the next
    /// model's hole is its own. See the ground cut in SceneModel.metal.
    static let groundHoleBit: UInt32 = 0x40

    /// The flat map's standing surfaces (buildings, scene models) raise this
    /// bit as they draw, on top of whatever priority mark is under them,
    /// and the horizon's ground-side draw fails where it is set: the haze
    /// is decided from the view ray as if every painted pixel were the
    /// ground, and a wall crossing the horizon row would otherwise take the
    /// far ground's haze at that row. A building keeps its own colour and
    /// the ground beside it is veiled.
    static let surfaceMaskBit: UInt32 = 0x80
}
