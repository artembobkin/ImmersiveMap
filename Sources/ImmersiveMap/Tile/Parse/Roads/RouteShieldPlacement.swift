// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// A place along a road where the road's route signs could stand: a point
/// of the road's line in tile units, with the signs and the style they
/// draw in.
struct RouteShieldCandidate {
    let shields: [RouteShield]
    let style: RouteShieldStyle
    /// The key of the road's style, the key the numbers' glyph runs are
    /// grouped under.
    let styleKey: Int
    let position: SIMD2<Float>
    /// The signs' identity within the tile: two roads carrying the same
    /// numbers (the two carriageways of a motorway, the pieces the tile
    /// cut a route into) share it and are spaced as one.
    let group: String
}

/// Where a tile's route signs stand. The road reader offers a candidate
/// every `candidateStepTileUnits` along every signed road, and the tile
/// keeps, per group of identical signs, the candidates nearest the tile's
/// centre that stand `RouteShieldStyle.spacingPoints` apart. A route
/// crossing a tile then carries one set of signs near the middle of its
/// run through the tile, the neighbour's set is about a tile away, and the
/// two carriageways of a motorway, or its pieces, never stack two copies.
/// The frame's collision pass decides the rest.
enum RouteShieldPlacement {
    /// The distance between two candidates along a road, in tile units: a
    /// sixteenth of the tile.
    static let candidateStepTileUnits: Float = 256
    /// A tile's side in layout points at the reference scale, the ratio
    /// the spacing crosses into tile units by (as the road label anchors
    /// do in `TileRoadLabelsBuilder`).
    static let tileScreenPointSize: Float = 256

    /// The candidates along a line in tile units, every
    /// `candidateStepTileUnits` from half a step in, the points outside
    /// the tile skipped.
    static func candidatePoints(along points: [SIMD2<Float>], tileExtent: Float) -> [SIMD2<Float>] {
        guard points.count >= 2 else {
            return []
        }
        var candidates: [SIMD2<Float>] = []
        var nextDistance = candidateStepTileUnits * 0.5
        var travelled: Float = 0
        for index in 1..<points.count {
            let start = points[index - 1]
            let segment = points[index] - start
            let length = simd_length(segment)
            guard length > 0 else {
                continue
            }
            while nextDistance <= travelled + length {
                let point = start + segment * ((nextDistance - travelled) / length)
                if point.x >= 0, point.y >= 0, point.x <= tileExtent, point.y <= tileExtent {
                    candidates.append(point)
                }
                nextDistance += candidateStepTileUnits
            }
            travelled += length
        }
        return candidates
    }

    /// The candidates kept, per group in the order the groups were first
    /// offered: nearest the tile's centre first, each at least the style's
    /// spacing from every one kept before it.
    static func select(_ candidates: [RouteShieldCandidate], tileExtent: Float) -> [RouteShieldCandidate] {
        var groupOrder: [String] = []
        var candidatesByGroup: [String: [RouteShieldCandidate]] = [:]
        for candidate in candidates {
            if candidatesByGroup[candidate.group] == nil {
                groupOrder.append(candidate.group)
            }
            candidatesByGroup[candidate.group, default: []].append(candidate)
        }
        let centre = SIMD2<Float>(repeating: tileExtent * 0.5)
        let unitsPerPoint = tileExtent / tileScreenPointSize
        var selected: [RouteShieldCandidate] = []
        for group in groupOrder {
            guard let groupCandidates = candidatesByGroup[group] else { continue }
            let ordered = groupCandidates.sorted { lhs, rhs in
                let lhsDistance = simd_distance_squared(lhs.position, centre)
                let rhsDistance = simd_distance_squared(rhs.position, centre)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
                return lhs.position.y < rhs.position.y
            }
            var kept: [SIMD2<Float>] = []
            for candidate in ordered {
                let spacing = candidate.style.spacingPoints * unitsPerPoint
                let spacingSquared = spacing * spacing
                guard kept.allSatisfy({ simd_distance_squared($0, candidate.position) >= spacingSquared }) else {
                    continue
                }
                kept.append(candidate.position)
                selected.append(candidate)
            }
        }
        return selected
    }
}
