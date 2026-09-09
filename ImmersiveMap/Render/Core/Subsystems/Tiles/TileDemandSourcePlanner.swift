// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The frame's demanded source tiles: every target, and for each target
/// that is not resident yet, at most one stand-in ancestor that is already
/// available locally (resident, or prepared on disk). Built once per frame
/// and read in two orders, the stable one for the placement hash and the
/// camera order for the request, so both carry exactly the same tiles even
/// if the disk index moves between the two reads.
struct TileDemandSourcePlan {
    /// Target-first order: each target followed by its stand-in, deduplicated.
    let demandedSourceTiles: [Tile]
    /// The stand-in chosen per target tile; absent when the target is
    /// resident or nothing of it is available locally.
    let fallbackAncestorByTarget: [Tile: Tile]

    /// The same tiles walked in the given target order, each target followed
    /// by its stand-in, deduplicated. A tile the given order does not reach
    /// (the orders should name the same targets) is appended at the end so
    /// the contents always match `demandedSourceTiles`.
    func demandedSourceTiles(orderedBy targets: [VisibleTile]) -> [Tile] {
        var ordered: [Tile] = []
        ordered.reserveCapacity(demandedSourceTiles.count)
        var seen: Set<Tile> = []
        func append(_ tile: Tile) {
            if seen.insert(tile).inserted {
                ordered.append(tile)
            }
        }
        for target in targets {
            append(target.tile)
            if let fallback = fallbackAncestorByTarget[target.tile] {
                append(fallback)
            }
        }
        for tile in demandedSourceTiles {
            append(tile)
        }
        return ordered
    }
}

enum TileDemandSourcePlanner {
    /// `backdropZoomLevel` is the flat map's z3 backdrop when one is drawn:
    /// no stand-in at that zoom or coarser is worth demanding, the backdrop
    /// already paints it. Nil on the globe and on a flat map no deeper than
    /// z3, where the walk goes down to z0 (the pinned world cover). The
    /// closures answer from the working set and the disk index; the
    /// availability answers are memoized per ancestor, so siblings sharing
    /// a parent cost one lookup.
    static func makePlan(targets: [VisibleTile],
                         backdropZoomLevel: Int?,
                         isResident: (Tile) -> Bool,
                         isAvailableLocally: (Tile) -> Bool) -> TileDemandSourcePlan {
        var demanded: [Tile] = []
        demanded.reserveCapacity(targets.count * 2)
        var seen: Set<Tile> = []
        var fallbackByTarget: [Tile: Tile] = [:]
        var availability: [Tile: Bool] = [:]
        let lowestZoom = backdropZoomLevel.map { $0 + 1 } ?? 0

        func append(_ tile: Tile) {
            if seen.insert(tile).inserted {
                demanded.append(tile)
            }
        }
        func isAvailable(_ tile: Tile) -> Bool {
            if let known = availability[tile] {
                return known
            }
            let answer = isAvailableLocally(tile)
            availability[tile] = answer
            return answer
        }

        for target in targets {
            let source = target.tile
            append(source)
            if let fallback = fallbackByTarget[source] {
                append(fallback)
                continue
            }
            guard source.z > lowestZoom, isResident(source) == false else {
                continue
            }
            for zoom in stride(from: source.z - 1, through: lowestZoom, by: -1) {
                guard let ancestor = source.findParentTile(atZoom: zoom) else {
                    continue
                }
                if isAvailable(ancestor) {
                    fallbackByTarget[source] = ancestor
                    append(ancestor)
                    break
                }
            }
        }

        return TileDemandSourcePlan(demandedSourceTiles: demanded,
                                    fallbackAncestorByTarget: fallbackByTarget)
    }
}
