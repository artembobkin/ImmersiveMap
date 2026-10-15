// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The flat map's tile-priority stencil value (`TileSourceStencilPriority`):
/// the zoom of a source, one to thirty-one, the cleared stencil's 0 kept
/// for ground nobody was given.
///
/// On the flat map the stencil carries the planner's decision, not a
/// contest between the sources. Before the ground draws, the placement
/// prepass (`PlacementStencilRenderSubsystem`) marks the ground of every
/// placement with the zoom of its source: a tile in its own slot and an
/// ancestor standing in mark the slot, a descendant standing in marks its
/// own square, the finer marks drawn over the coarser. Every ground pass
/// then draws its source at full extent and tests `equal` to the source's
/// zoom, so a tile paints exactly the ground the planner gave it, and
/// nothing else: not a finer tile's ground it reaches over, not a slot
/// another stand-in holds, whatever the order of the draws and whatever
/// the depth says on a relief. Two tiles of one zoom never share a
/// pixel, so the zoom names the source. The sphere keeps its own scheme
/// (`TileSourceStencilPriority.reference(sourceZoom:)`).
enum FlatTileStencilPacking {
    /// The bits of the zoom, 1 to 31, 0 kept for the cleared stencil.
    static let zoomMask: UInt32 = 0x1F

    /// The value of a source of `sourceZoom`.
    static func reference(sourceZoom: Int) -> UInt32 {
        UInt32(min(max(sourceZoom, 0), Int(zoomMask) - 1) + 1)
    }
}
