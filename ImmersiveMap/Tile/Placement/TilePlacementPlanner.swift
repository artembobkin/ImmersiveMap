// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The frame's placements, a function of the targets and of what is
/// resident right now: nothing is carried from one frame's placement to
/// the next. A target that is resident draws itself. A target that is not
/// yet resident draws a stand-in from the resident tiles, in this order:
///
/// 1. its resident descendants when they cover it whole (a zoom-out shows
///    the detailed children until the parent arrives);
/// 2. its finest resident ancestor above the backdrop's zoom (a zoom-in or
///    a pan shows the parent until the child arrives);
/// 3. whatever resident descendants it has, with holes (better than an
///    empty region);
/// 4. nothing: the backdrop paints it, or the globe's placeholder.
///
/// `backdropZoomLevel` is the zoom of the full-screen backdrop already drawn
/// under the main coverage (flat mode). Substitutes at that zoom or coarser
/// carry nothing the backdrop does not, so they are never placed. Nil on
/// the globe and when no backdrop is drawn.
///
/// Targets may overlap (a parent under its children on the flat map), so
/// the same stand-in can be found for two targets; the output holds it
/// once.
struct TilePlacementPlanner {
    /// How many levels below a target the descendant search goes: a
    /// zoom-out of more than this many levels shows the ancestor instead.
    static let descendantSearchDepth = 3

    /// `descendantSearchDepth` 0 turns the descendant stand-ins off: the
    /// backdrop's z3 targets are covered by the main coverage's finer tiles
    /// already, and placing them a second time would draw them twice.
    static func buildPlacements(targets: [VisibleTile],
                                resident: [Tile: MetalTile],
                                zoom: Int,
                                backdropZoomLevel: Int? = nil,
                                descendantSearchDepth: Int = descendantSearchDepth) -> PlaceTilesContext {
        // The ancestors of every resident tile, so the descendant search
        // only descends into branches that hold something.
        var branches = Set<Tile>()
        for tile in resident.keys {
            var ancestor = tile
            while true {
                guard branches.insert(ancestor).inserted else { break }
                guard ancestor.z > 0, let parent = ancestor.findParentTile(atZoom: ancestor.z - 1) else { break }
                ancestor = parent
            }
        }

        /// The resident descendants of `tile` down to the search depth, and
        /// whether they cover it whole.
        func descendants(of tile: Tile, loop: Int8, depth: Int) -> (placements: [PlaceTile], complete: Bool) {
            if let metalTile = resident[tile] {
                return ([PlaceTile(metalTile: metalTile, placeIn: VisibleTile(tile: tile, loop: loop), lodKind: .retainedReplacement)], true)
            }
            guard depth > 0, branches.contains(tile) else {
                return ([], false)
            }
            var placements: [PlaceTile] = []
            var complete = true
            for child in children(of: tile) {
                let resolved = descendants(of: child, loop: loop, depth: depth - 1)
                placements.append(contentsOf: resolved.placements)
                complete = complete && resolved.complete
            }
            return (placements, complete)
        }

        func isUsefulSubstitute(_ tile: Tile) -> Bool {
            guard let backdropZoomLevel else { return true }
            return tile.z > backdropZoomLevel
        }

        var placeTiles: [PlaceTile] = []
        var seen = Set<PlaceTile>()
        func append(_ placement: PlaceTile) {
            if seen.insert(placement).inserted {
                placeTiles.append(placement)
            }
        }

        for target in targets {
            let sourceTile = target.tile
            if let metalTile = resident[sourceTile] {
                append(PlaceTile(metalTile: metalTile,
                                 placeIn: target,
                                 lodKind: sourceTile.z < zoom ? .coarseSubstitute : .exact))
                continue
            }

            let below: (placements: [PlaceTile], complete: Bool) = descendantSearchDepth > 0 && branches.contains(sourceTile)
                ? descendants(of: sourceTile, loop: target.loop, depth: descendantSearchDepth)
                : (placements: [], complete: false)
            if below.complete, below.placements.isEmpty == false {
                below.placements.forEach(append)
                continue
            }

            var ancestorPlacement: PlaceTile?
            if sourceTile.z > 0 {
                for ancestorZoom in stride(from: sourceTile.z - 1, through: 0, by: -1) {
                    guard let ancestor = sourceTile.findParentTile(atZoom: ancestorZoom), isUsefulSubstitute(ancestor) else {
                        break
                    }
                    if let metalTile = resident[ancestor] {
                        ancestorPlacement = PlaceTile(metalTile: metalTile, placeIn: target, lodKind: .coarseSubstitute)
                        break
                    }
                }
            }
            if let ancestorPlacement {
                append(ancestorPlacement)
                continue
            }
            below.placements.forEach(append)
        }

        return PlaceTilesContext(tilePlacements: placeTiles)
    }

    private static func children(of tile: Tile) -> [Tile] {
        let x = tile.x * 2
        let y = tile.y * 2
        let z = tile.z + 1
        return [Tile(x: x, y: y, z: z), Tile(x: x + 1, y: y, z: z),
                Tile(x: x, y: y + 1, z: z), Tile(x: x + 1, y: y + 1, z: z)]
    }
}
