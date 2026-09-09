// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The flat map's building coverage: which resident tiles draw their
/// buildings this frame, as a partition of the ground with no overlaps.
///
/// The ground coverage may overlap (a coarse parent under fine children,
/// resolved per pixel by the tile-priority stencil), and buildings cannot
/// live with that: a wall rises into the pixels of the ground behind it,
/// so a pixel test cannot tell the parent's copy of a building from the
/// child's, and the two versions cut through each other. Buildings are
/// owned by ground area instead. The planner takes the tiles resident in
/// the working set (the retention included), never demands more, and
/// hands every slot of the building quadtree to exactly one of them:
///
/// - the grid is the `minimumSourceZoom` tiles (z14, the zoom where the
///   tiles carry real buildings; coarser tiles merge them into blocks of one
///   height and are never used), split down to the target zoom into the
///   slots the view needs (a slot no visible tile lies in is not needed,
///   since nothing of it is on screen);
/// - a needed slot draws the finest resident tile that covers it: a
///   resident tile draws itself at its own extent wherever no resident
///   descendant the view needs lies under it, and clipped to the slots of
///   the needed descendants it has none for. So the nearest loaded tile
///   always draws its own buildings, and its loaded neighbours never lose
///   theirs because a farther sibling has not arrived; the parent fills
///   only the slots that are actually missing, cut at the slot's edge the
///   way the ground's stencil cuts the coarse ground under a fine tile;
/// - a slot with no resident tile at or above it (down from the grid)
///   borrows nothing coarser than the grid: it stays empty until its tile
///   arrives, and the resident tiles under it draw what they have;
/// - cells farther than `fieldRadiusInCells` from the eye's ground point
///   are skipped: buildings are a near-field feature;
/// - a frame whose target zoom is coarser than the grid draws no
///   buildings at all: its ground carries none, and the retention's tiles
///   from a closer view would draw as islands.
///
/// A clipped placement (`placeIn` below the source) is drawn with the
/// vertex-stage slot clip; the result is otherwise drawn with the depth
/// test alone, no stencil, by the building and shadow passes.
enum BuildingCoveragePlanner {
    /// The zoom of the building grid and the coarsest tile that may draw
    /// buildings.
    static let minimumSourceZoom = 14
    /// How far from the eye's ground point, in grid cells, buildings are
    /// drawn.
    static let fieldRadiusInCells: Double = 3

    /// `resident` is every tile in the working set; `visibleTiles` the
    /// frame's visible tiles at the target zoom, which decide which
    /// children a cell needs; `eyeGroundCell` the eye's ground point in
    /// grid cell units (a z14 tile is one unit), nil for the globe, where
    /// nothing is extruded.
    static func plan(resident: [Tile: MetalTile],
                     visibleTiles: [VisibleTile],
                     eyeGroundCell: SIMD2<Double>?) -> PlaceTilesContext {
        // Coarser than the grid nothing draws: the ground tiles carry no
        // buildings there, and whatever the retention still holds from a
        // closer view would draw as islands of its own outline.
        guard let eyeGroundCell, let targetZoom = visibleTiles.first?.z, targetZoom >= minimumSourceZoom else {
            return .empty
        }
        struct Key: Hashable {
            let tile: Tile
            let loop: Int8
        }

        // What the view needs, per world copy: the visible tiles at the
        // target zoom and every ancestor of one down to the grid.
        var visibleByLoop: [Int8: Set<Tile>] = [:]
        var visibleAncestorsByLoop: [Int8: Set<Tile>] = [:]
        for tile in visibleTiles where tile.z == targetZoom {
            visibleByLoop[tile.loop, default: []].insert(tile.tile)
            var ancestor = tile.tile
            while ancestor.z > minimumSourceZoom, let parent = ancestor.findParentTile(atZoom: ancestor.z - 1) {
                ancestor = parent
                visibleAncestorsByLoop[tile.loop, default: []].insert(ancestor)
            }
        }
        func isNeeded(_ tile: Tile, loop: Int8) -> Bool {
            if tile.z >= targetZoom {
                let atTarget = tile.z == targetZoom ? tile : tile.findParentTile(atZoom: targetZoom)
                return atTarget.map { visibleByLoop[loop]?.contains($0) ?? false } ?? false
            }
            return visibleAncestorsByLoop[loop]?.contains(tile) ?? false
        }

        // The resident tiles of the grid and below, every ancestor of one
        // down to the grid (the branches worth descending into), and the
        // cells they belong to, per world copy the view shows.
        var present = Set<Key>()
        var cells = Set<Key>()
        for loop in visibleByLoop.keys {
            for tile in resident.keys where tile.z >= minimumSourceZoom && isNeeded(tile, loop: loop) {
                var ancestor = tile
                while true {
                    present.insert(Key(tile: ancestor, loop: loop))
                    if ancestor.z == minimumSourceZoom {
                        cells.insert(Key(tile: ancestor, loop: loop))
                        break
                    }
                    guard let parent = ancestor.findParentTile(atZoom: ancestor.z - 1) else {
                        break
                    }
                    ancestor = parent
                }
            }
        }

        /// The placements under `tile`. `cover` is the finest resident tile
        /// at or above `tile` (nil when there is none down from the grid).
        /// A needed child with resident tiles under it resolves on its own;
        /// every other needed child is a slot the cover draws into, clipped;
        /// a tile with nothing resident under it draws the cover whole.
        func resolve(_ tile: Tile, loop: Int8, cover: MetalTile?) -> [PlaceTile] {
            let cover = resident[tile] ?? cover
            let needed = tile.z < targetZoom ? children(of: tile).filter { isNeeded($0, loop: loop) } : []
            let branches = needed.filter { present.contains(Key(tile: $0, loop: loop)) }
            guard let cover else {
                return branches.flatMap { resolve($0, loop: loop, cover: nil) }
            }
            func place(in slot: Tile) -> PlaceTile {
                PlaceTile(metalTile: cover,
                          placeIn: VisibleTile(tile: slot, loop: loop),
                          lodKind: cover.tile == slot ? .exact : .coarseSubstitute)
            }
            if branches.isEmpty {
                return [place(in: tile)]
            }
            var placements: [PlaceTile] = []
            for child in needed {
                if present.contains(Key(tile: child, loop: loop)) {
                    placements.append(contentsOf: resolve(child, loop: loop, cover: cover))
                } else {
                    placements.append(place(in: child))
                }
            }
            return placements
        }

        var result: [PlaceTile] = []
        let cellsCount = Double(1 << minimumSourceZoom)
        for cell in cells {
            let center = SIMD2<Double>(Double(cell.tile.x) + Double(cell.loop) * cellsCount + 0.5,
                                       Double(cell.tile.y) + 0.5)
            guard simd_length(center - eyeGroundCell) <= fieldRadiusInCells else {
                continue
            }
            result.append(contentsOf: resolve(cell.tile, loop: cell.loop, cover: nil))
        }
        result.sort { lhs, rhs in
            if lhs.placeIn.z != rhs.placeIn.z {
                return lhs.placeIn.z > rhs.placeIn.z
            }
            if lhs.placeIn.loop != rhs.placeIn.loop {
                return lhs.placeIn.loop < rhs.placeIn.loop
            }
            if lhs.placeIn.x != rhs.placeIn.x {
                return lhs.placeIn.x < rhs.placeIn.x
            }
            return lhs.placeIn.y < rhs.placeIn.y
        }
        return PlaceTilesContext(tilePlacements: result)
    }

    private static func children(of tile: Tile) -> [Tile] {
        let x = tile.x * 2
        let y = tile.y * 2
        let z = tile.z + 1
        return [Tile(x: x, y: y, z: z), Tile(x: x + 1, y: y, z: z),
                Tile(x: x, y: y + 1, z: z), Tile(x: x + 1, y: y + 1, z: z)]
    }
}
