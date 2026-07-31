// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct TilePlacementPlanner {
    /// `backdropZoomLevel` - zoom of the full-screen backdrop already drawn
    /// UNDER the main coverage (flat mode). Substitutes at this zoom or coarser
    /// carry no information on top of the backdrop, so they do not compete with
    /// detailed partial slots: without the filter, the pinned z3 backdrop won
    /// over any incomplete retained coverage, while slots that fell to z3 do
    /// not participate in the parent's coverage - and on zoom-out the coarse
    /// zone crept from the edges across the whole screen over a few rebuilds.
    /// nil - no backdrop (globe).
    static func buildPlacements(targets: [VisibleTile],
                                readyTilesBySource: [Tile: MetalTile?],
                                zoom: Int,
                                previousContext: PlaceTilesContext,
                                backdropZoomLevel: Int? = nil) -> PlaceTilesContext {
        var placeTiles: [PlaceTile] = []
        let readyReplacementCandidates = readyTilesBySource.values.compactMap { $0 }.sorted { lhs, rhs in
            if lhs.tile.z != rhs.tile.z {
                return lhs.tile.z > rhs.tile.z
            }
            if lhs.tile.x != rhs.tile.x {
                return lhs.tile.x < rhs.tile.x
            }
            return lhs.tile.y < rhs.tile.y
        }

        for target in targets {
            let sourceTile = target.tile
            let lodKind: TileLodKind = sourceTile.z < zoom ? .coarseSubstitute : .exact
            let metalTile = readyTilesBySource[sourceTile] ?? nil

            // A substitute is useful only if it is more detailed than the backdrop under the coverage.
            func isUsefulSubstitute(_ tile: Tile) -> Bool {
                guard let backdropZoomLevel else {
                    return true
                }
                return tile.z > backdropZoomLevel
            }

            func bestFullReplacement() -> MetalTile? {
                var bestReplacement: MetalTile?
                for prev in previousContext.tilePlacements {
                    let prevSourceTile = prev.metalTile.tile

                    guard isUsefulSubstitute(prevSourceTile) else {
                        continue
                    }
                    // Previous tile fully covers the required tile
                    // (including exact same tile identity).
                    if prevSourceTile == target.tile || prevSourceTile.covers(target.tile) {
                        // Keep the most detailed fallback source among
                        // all covering tiles from the previous frame.
                        if prevSourceTile.z > (bestReplacement?.tile.z ?? Int.min) {
                            bestReplacement = prev.metalTile
                        }
                    }
                }
                return bestReplacement
            }

            func collectPartialReplacements() -> (placements: [PlaceTile], coversTarget: Bool) {
                var partialPlacements: [PlaceTile] = []
                var uniquePlaceInTiles: Set<Tile> = []
                for prev in previousContext.tilePlacements {
                    let prevMetalTile = prev.metalTile
                    let prevSourceTile = prev.metalTile.tile

                    // Previous tile is inside the required tile
                    // (including exact same tile identity).
                    // Compare by placeIn.loop: content is shared between wrapped
                    // copies, but a placement is drawn strictly in the world copy
                    // of its placeIn - it does not paint the target's copy in
                    // another loop.
                    if prev.placeIn.loop == target.loop,
                       prevSourceTile == target.tile || target.tile.covers(prevSourceTile) {
                        partialPlacements.append(PlaceTile(metalTile: prevMetalTile,
                                                           placeIn: prev.placeIn,
                                                           lodKind: .retainedReplacement))
                        uniquePlaceInTiles.insert(prev.placeIn.tile)
                    }
                }

                // Coverage is the area of the UNION of placeIn slots (a slot of
                // depth d occupies 1/4^d of the target's area): exactly the
                // placeIn region is drawn (fragment clip), not the whole source.
                // Slots from different generations can be nested - ones nested
                // inside an already-counted coarser slot add no area.
                var coveredFraction = 0.0
                var countedPlaceInTiles: [Tile] = []
                for placeInTile in uniquePlaceInTiles.sorted(by: { ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y) }) {
                    if countedPlaceInTiles.contains(where: { $0.covers(placeInTile) }) {
                        continue
                    }
                    countedPlaceInTiles.append(placeInTile)
                    let depth = placeInTile.z - target.tile.z
                    coveredFraction += depth >= 30 ? 0 : 1.0 / Double(1 << (2 * depth))
                }
                return (partialPlacements, coveredFraction >= 0.999_999)
            }

            func bestReadyParent() -> MetalTile? {
                for candidate in readyReplacementCandidates {
                    let candidateTile = candidate.tile
                    guard candidateTile != target.tile,
                          candidateTile.covers(target.tile),
                          isUsefulSubstitute(candidateTile) else {
                        continue
                    }
                    return candidate
                }

                return nil
            }

            // Substitution cascade for a missing target - maximum detail first:
            // 1) previous tiles INSIDE the target (always more detailed than any
            //    covering source), but only if they cover it entirely -
            //    detailed content with holes is worse than full coarse content;
            // 2) the more detailed of: the previous frame's covering source
            //    (retention, including the target itself via a strong reference)
            //    and a ready parent from the cache; on a tie - the cached
            //    parent (fresher);
            // 3) incomplete previous tiles - better than an empty region.
            // Two sources never mix in one slot: overlapping yields a double
            // blend of translucent layers (roads).
            if metalTile == nil {
                let partial = collectPartialReplacements()
                if partial.coversTarget {
                    placeTiles.append(contentsOf: partial.placements)
                    continue
                }

                let readyParent = bestReadyParent()
                let fullReplacement = bestFullReplacement()
                if let fullReplacement, fullReplacement.tile.z > (readyParent?.tile.z ?? Int.min) {
                    placeTiles.append(PlaceTile(metalTile: fullReplacement,
                                                placeIn: target,
                                                lodKind: .retainedReplacement))
                } else if let readyParent {
                    placeTiles.append(PlaceTile(metalTile: readyParent,
                                                placeIn: target,
                                                lodKind: .retainedReplacement))
                } else {
                    placeTiles.append(contentsOf: partial.placements)
                }

                continue
            }

            placeTiles.append(PlaceTile(metalTile: metalTile!,
                                        placeIn: target,
                                        lodKind: lodKind))
        }

        return PlaceTilesContext(tilePlacements: placeTiles)
    }
}
