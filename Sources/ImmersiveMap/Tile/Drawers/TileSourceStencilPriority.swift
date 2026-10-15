// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The tile-priority stencil, on either surface: the planner's decision,
/// enforced per pixel. Before the ground draws, the placement prepass
/// (`PlacementStencilRenderSubsystem`) marks the ground of every
/// placement with the zoom of its source, the finer marks over the
/// coarser, and every tile pass then draws its source at full extent, in
/// every slot it stands in at once, and tests `equal` to the source's
/// zoom: a tile paints exactly the ground the planner gave it, and
/// nothing else, whatever the order of the draws and whatever the depth
/// says on a relief. Two tiles of one zoom never share a pixel, so the
/// zoom names the source, and same-zoom neighbours keep painting their
/// stitching margins over each other. Nothing is cut to a slot on the
/// CPU or in the vertex stage, and no tile pass writes the priority. The
/// bits above the priority serve both surfaces.
enum TileSourceStencilPriority {
    /// The reference of a source, 1...17: zoom clamped to the tile
    /// scheme's range, plus one so the cleared stencil (0) reads as
    /// "ground nobody was given".
    static func reference(sourceZoom: Int) -> UInt32 {
        UInt32(min(max(sourceZoom, 0), 16) + 1)
    }

    /// The bits the priority lives in, six: the prepass writes and every
    /// tile pass reads the stencil through this mask, so the flags above
    /// stay out of its way.
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
