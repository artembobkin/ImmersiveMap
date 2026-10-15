// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The frame's placements, a function of the targets, of what is resident
/// right now, and of what the last frame showed. A target that is
/// resident draws itself. A target that is not yet resident draws its
/// stand-ins:
///
/// - first, what the last frame showed on its ground (`previous`), while
///   it is still resident: the ground keeps the tiles it has until the
///   target itself lands. A tile that arrives for a target the camera has
///   left behind (a fast zoom asks for every level on the way) is never
///   shown: it would replace what stands there only to be replaced again.
///   Then, where the last frame showed nothing (ground the camera has
///   just turned to), the resident tiles:
/// - its resident descendants, at any depth, whether or not they cover it
///   whole: a zoom-out keeps showing the detailed tiles the camera was
///   looking at until the parent arrives, however far the zoom has run
///   ahead of the loads (the eye has settled on that ground; swapping it
///   for something coarser and then for the target is two cuts instead of
///   one), and a fast zoom-out, where only some of them had landed, keeps
///   the ones that had;
/// - and, wherever those leave a hole, its finest resident ancestor above
///   the backdrop's zoom: a zoom-in or a pan shows the parent until the
///   child arrives. The ancestor is placed whole; the placement prepass
///   marks every placement's ground in the tile-priority stencil, the
///   finer over the coarser, and the ground paints by equality on both
///   surfaces (`TileSourceStencilPriority`), so the descendants stay on
///   top and the ancestor shows through the holes only;
/// - nothing, when neither exists: the backdrop paints it, or the globe's
///   placeholder.
///
/// `backdropZoomLevel` is the zoom of the full-screen backdrop already drawn
/// under the main coverage (flat mode). Substitutes at that zoom or coarser
/// carry nothing the backdrop does not, so they are never placed. Nil on
/// the globe and when no backdrop is drawn.
///
/// Targets may overlap (a parent under its children on the flat map), so
/// the same stand-in can be found for two targets; the output holds it
/// once.
///
/// A placement draws by `TileDrawRules`: a target by its slot's, from
/// `slotRules`, and a stand-in by the rules of its own slot when it is a
/// target of the frame too (the same world copy), else by the slot's it
/// fills. A source drawn in its own slot somewhere thus draws the same
/// way everywhere, and a pan changes nothing on screen until the tile
/// it opened a slot for lands.
struct TilePlacementPlanner {
    /// How many levels below a target the descendant search goes: the
    /// whole tree, a resident tile stands in for a loading ancestor at any
    /// depth. The search only descends into branches that hold a resident
    /// tile, so its cost is the resident tiles' ancestor chains, not the
    /// tree.
    static let descendantSearchDepth = Int.max

    /// `descendantSearchDepth` 0 turns the descendant stand-ins off: the
    /// backdrop's targets are covered by the main coverage's finer tiles
    /// already, and placing them a second time would draw them twice.
    static func buildPlacements(targets: [VisibleTile],
                                resident: [Tile: MetalTile],
                                zoom: Int,
                                backdropZoomLevel: Int? = nil,
                                descendantSearchDepth: Int = descendantSearchDepth,
                                previous: [PlaceTile] = [],
                                slotRules: (VisibleTile) -> TileDrawRules = { _ in .all }) -> PlaceTilesContext {
        // The targets by their tile and world copy: a stand-in that is a
        // target itself draws by its own slot's rules.
        let targetSlots = Set(targets)
        func rules(of source: Tile, in slot: VisibleTile) -> TileDrawRules {
            let own = VisibleTile(tile: source, worldWrap: slot.worldWrap)
            return slotRules(targetSlots.contains(own) ? own : slot)
        }
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
        /// whether they cover it whole. Each is placed at its own extent,
        /// for the target's slot.
        func descendants(of tile: Tile, slot: VisibleTile, depth: Int) -> (placements: [PlaceTile], complete: Bool) {
            if let metalTile = resident[tile] {
                let placeIn = VisibleTile(tile: tile, worldWrap: slot.worldWrap)
                return ([PlaceTile(metalTile: metalTile, placeIn: placeIn, slot: slot, rules: rules(of: tile, in: slot))], true)
            }
            guard depth > 0, branches.contains(tile) else {
                return ([], false)
            }
            var placements: [PlaceTile] = []
            var complete = true
            for child in children(of: tile) {
                let resolved = descendants(of: child, slot: slot, depth: depth - 1)
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

        // What the last frame showed and is still resident, indexed once
        // per plan so a target finds it in as many lookups as there are
        // zooms above it, not by a scan of every placement: by the ground
        // a placement stood on (its `placeIn`, the square the prepass
        // marked for it), and under every ancestor of that ground, in the
        // last frame's order.
        var shownByGround: [VisibleTile: [PlaceTile]] = [:]
        var shownInsideByAncestor: [VisibleTile: [PlaceTile]] = [:]
        for shown in previous {
            let tile = shown.metalTile.tile
            guard resident[tile] != nil, isUsefulSubstitute(tile) else { continue }
            let ground = shown.placeIn
            shownByGround[ground, default: []].append(shown)
            var ancestorZoom = ground.z - 1
            while ancestorZoom >= 0, let ancestor = ground.tile.findParentTile(atZoom: ancestorZoom) {
                shownInsideByAncestor[VisibleTile(tile: ancestor, worldWrap: ground.worldWrap), default: []].append(shown)
                ancestorZoom -= 1
            }
        }

        for target in targets {
            let sourceTile = target.tile
            if let metalTile = resident[sourceTile] {
                append(PlaceTile(metalTile: metalTile,
                                 placeIn: target,
                                 rules: slotRules(target)))
                continue
            }

            // What stood on this ground last frame and is still resident,
            // by the ground it stood on (`placeIn`, the square the prepass
            // marked for it), not by its tile: the placements inside the
            // slot keep their squares, and the one whose square covers the
            // slot, the finest such, fills the rest. A tile that arrived
            // for a far slot of its own is not what stood on this ground,
            // whatever its zoom, and does not take it: a ground changes
            // only to its own target. Each is drawn no worse than it was
            // shown and no worse than the slot asks (`TileDrawRules.finer`):
            // the ground keeps not only its tiles but their look, a vector
            // tile with its labels stays one when the camera pulls back,
            // and a far ring's texture turns into its geometry when the
            // camera comes near, until the slot's own tile lands.
            let shownInside = shownInsideByAncestor[target] ?? []
            // The finest ground over the slot: the slot itself, then its
            // ancestors upward.
            var shownOver: PlaceTile?
            var groundZoom = sourceTile.z
            while shownOver == nil, groundZoom >= 0, let ground = sourceTile.findParentTile(atZoom: groundZoom) {
                shownOver = shownByGround[VisibleTile(tile: ground, worldWrap: target.worldWrap)]?.first
                groundZoom -= 1
            }
            for shown in shownInside {
                let tile = shown.metalTile.tile
                append(PlaceTile(metalTile: resident[tile]!,
                                 placeIn: shown.placeIn,
                                 slot: target,
                                 rules: shown.rules.finer(than: rules(of: tile, in: target))))
            }
            if let shownOver {
                let tile = shownOver.metalTile.tile
                append(PlaceTile(metalTile: resident[tile]!,
                                 placeIn: target,
                                 rules: shownOver.rules.finer(than: rules(of: tile, in: target))))
                continue
            }

            // Ground nothing was shown on, or the holes between what was:
            // the resident tiles, the descendants first where nothing at
            // all was shown.
            if shownInside.isEmpty {
                let below: (placements: [PlaceTile], complete: Bool) = descendantSearchDepth > 0 && branches.contains(sourceTile)
                    ? descendants(of: sourceTile, slot: target, depth: descendantSearchDepth)
                    : (placements: [], complete: false)
                below.placements.forEach(append)
                if below.complete, below.placements.isEmpty == false {
                    continue
                }
            }

            // The holes between the descendants or what was shown, or the
            // whole target when there are none: the finest resident
            // ancestor, drawn under them.
            if sourceTile.z > 0 {
                for ancestorZoom in stride(from: sourceTile.z - 1, through: 0, by: -1) {
                    guard let ancestor = sourceTile.findParentTile(atZoom: ancestorZoom), isUsefulSubstitute(ancestor) else {
                        break
                    }
                    if let metalTile = resident[ancestor] {
                        append(PlaceTile(metalTile: metalTile, placeIn: target, rules: rules(of: ancestor, in: target)))
                        break
                    }
                }
            }
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
