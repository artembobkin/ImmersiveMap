// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  VisibleTilesPreprocessor.swift
//  ImmersiveMap
//

import Foundation

/// Optimizes visible tile instances after culling:
/// filters too-distant tiles, applies coarse LOD substitution
/// and returns a non-overlapping coverage set for placement.
///
/// Invariants:
/// - Output contains no overlapping targets inside the same `loop`.
/// - Output ordering is deterministic (`z desc`, then `loop/x/y asc`).
/// - The preprocessor never creates tiles outside source ancestry:
///   each selected tile is the input tile itself or one of its parents.
final class VisibleTilesPreprocessor {
    /// Радиус дистанционного фильтра (Чебышёв, в тайлах целевого зума).
    /// На него же опирается кламп кандидатов в `FlatVisibleTileResolver`:
    /// перечислять тайлы дальше этого радиуса бессмысленно — фильтр их выбросит.
    static let defaultMaxVisibleRelativeDistance = 15

    private let maxVisibleRelativeDistance: Int
    private let coarseRelativeDistanceThreshold: Int
    private let deepCoarseRelativeDistanceThreshold: Int

    init(maxVisibleRelativeDistance: Int = VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance,
         coarseRelativeDistanceThreshold: Int = 2,
         deepCoarseRelativeDistanceThreshold: Int = 10) {
        self.maxVisibleRelativeDistance = maxVisibleRelativeDistance
        self.coarseRelativeDistanceThreshold = coarseRelativeDistanceThreshold
        self.deepCoarseRelativeDistanceThreshold = deepCoarseRelativeDistanceThreshold
    }

    /// Runs the full preprocessing pipeline:
    /// 1) distance filter + preferred LOD stage,
    /// 2) deterministic priority sort,
    /// 3) non-overlapping coverage selection,
    /// 4) deterministic output sort.
    func preprocess(visibleTiles: [VisibleTile],
                    center: Center,
                    renderSurfaceMode: ViewMode) -> [VisibleTile] {
        let stagedInputs = buildStageInputs(visibleTiles: visibleTiles,
                                            center: center,
                                            renderSurfaceMode: renderSurfaceMode)
        let sortedInputs = sortInputsForSelection(stagedInputs)
        let selectedTargets = selectCoverageTargets(from: sortedInputs)
        return sortTargetsForOutput(selectedTargets)
    }

    /// Builds candidate inputs for selection.
    ///
    /// Invariants:
    /// - Every emitted `InputTile` has `relativeDistance <= maxVisibleRelativeDistance`.
    /// - `preferredZoom` is clamped to `[0...visibleTile.z]`.
    private func buildStageInputs(visibleTiles: [VisibleTile],
                                  center: Center,
                                  renderSurfaceMode: ViewMode) -> [InputTile] {
        var inputs: [InputTile] = []
        inputs.reserveCapacity(visibleTiles.count)

        for visibleTile in visibleTiles {
            let distance = maxRelativeDistance(tile: visibleTile,
                                               center: center,
                                               renderSurfaceMode: renderSurfaceMode)
            guard distance <= maxVisibleRelativeDistance else {
                continue
            }
            inputs.append(InputTile(visibleTile: visibleTile,
                                    relativeDistance: distance,
                                    preferredZoom: preferredZoom(for: visibleTile, distance: distance)))
        }

        return inputs
    }

    /// Orders candidates for greedy selection.
    ///
    /// Priority: finer preferred zoom -> closer distance -> stable tie-break by loop/x/y.
    /// This guarantees deterministic selection when input order is unstable.
    private func sortInputsForSelection(_ inputs: [InputTile]) -> [InputTile] {
        var sortedInputs = inputs
        // Finer tiles first; coarser tiles can fallback to finer levels to avoid overlap.
        sortedInputs.sort { lhs, rhs in
            if lhs.preferredZoom != rhs.preferredZoom {
                return lhs.preferredZoom > rhs.preferredZoom
            }
            if lhs.relativeDistance != rhs.relativeDistance {
                return lhs.relativeDistance < rhs.relativeDistance
            }
            let left = lhs.visibleTile
            let right = rhs.visibleTile
            if left.loop != right.loop {
                return left.loop < right.loop
            }
            if left.x != right.x {
                return left.x < right.x
            }
            return left.y < right.y
        }
        return sortedInputs
    }

    /// Greedily builds the final coverage set with overlap exclusion.
    ///
    /// Invariants:
    /// - At most one identical `VisibleTile` is selected.
    /// - No two selected targets overlap within the same `loop`.
    private func selectCoverageTargets(from inputs: [InputTile]) -> Set<VisibleTile> {
        var selected: Set<VisibleTile> = []
        selected.reserveCapacity(inputs.count)
        var coverage = SelectedCoverageIndex()

        for input in inputs {
            guard let chosenTarget = chooseTarget(for: input, coverage: &coverage) else {
                continue
            }
            if selected.insert(chosenTarget).inserted {
                coverage.insert(chosenTarget)
            }
        }

        return selected
    }

    /// Chooses the first acceptable target in the zoom range
    /// `[preferredZoom ... visibleTile.z]`.
    ///
    /// The method may return:
    /// - exact tile,
    /// - parent tile used as coarse substitute,
    /// - `nil` when all candidates overlap already selected coverage.
    private func chooseTarget(for input: InputTile,
                              coverage: inout SelectedCoverageIndex) -> VisibleTile? {
        let visibleTile = input.visibleTile
        for candidateZoom in input.preferredZoom...visibleTile.z {
            guard let candidate = targetTile(for: visibleTile, targetZoom: candidateZoom) else {
                continue
            }
            if coverage.containsExact(candidate) {
                return candidate
            }
            if coverage.hasCoverageOverlap(with: candidate) {
                continue
            }
            return candidate
        }
        return nil
    }

    /// Converts selected targets into renderer-stable output order.
    private func sortTargetsForOutput(_ targets: Set<VisibleTile>) -> [VisibleTile] {
        var result = Array(targets)
        result.sort { lhs, rhs in
            if lhs.z != rhs.z {
                return lhs.z > rhs.z
            }
            if lhs.loop != rhs.loop {
                return lhs.loop < rhs.loop
            }
            if lhs.x != rhs.x {
                return lhs.x < rhs.x
            }
            return lhs.y < rhs.y
        }
        return result
    }

    /// Precomputed selection metadata for one visible tile candidate.
    ///
    /// Invariants:
    /// - `preferredZoom <= visibleTile.z`.
    /// - `relativeDistance >= 0`.
    private struct InputTile {
        let visibleTile: VisibleTile
        let relativeDistance: Int
        let preferredZoom: Int
    }

    /// Fast overlap index for already selected tiles, partitioned by world `loop`.
    ///
    /// Data model:
    /// - `exactTilesByLoop`: exact selected tiles.
    /// - `ancestorOrExactTilesByLoop`: each selected tile plus all of its ancestors.
    ///
    /// This allows overlap checks in `O(z)` with no pairwise scan over all selected tiles.
    private struct SelectedCoverageIndex {
        private var exactTilesByLoop: [Int8: Set<Tile>] = [:]
        private var ancestorOrExactTilesByLoop: [Int8: Set<Tile>] = [:]

        /// Returns true only for exact selected tile identity in the same `loop`.
        func containsExact(_ tile: VisibleTile) -> Bool {
            exactTilesByLoop[tile.loop]?.contains(tile.tile) ?? false
        }

        /// Returns true when candidate overlaps already selected coverage in the same `loop`.
        ///
        /// Overlap is detected by two conditions:
        /// - candidate is ancestor-or-exact of an already selected tile,
        /// - candidate has an ancestor that is already selected exactly.
        func hasCoverageOverlap(with candidate: VisibleTile) -> Bool {
            if ancestorOrExactTilesByLoop[candidate.loop]?.contains(candidate.tile) ?? false {
                return true
            }

            guard let exactTiles = exactTilesByLoop[candidate.loop] else {
                return false
            }

            var ancestorX = candidate.x
            var ancestorY = candidate.y
            var ancestorZoom = candidate.z - 1

            while ancestorZoom >= 0 {
                let ancestor = Tile(x: ancestorX >> 1, y: ancestorY >> 1, z: ancestorZoom)
                if exactTiles.contains(ancestor) {
                    return true
                }
                ancestorX >>= 1
                ancestorY >>= 1
                ancestorZoom -= 1
            }

            return false
        }

        /// Inserts selected tile and all its ancestors into the index for its `loop`.
        mutating func insert(_ tile: VisibleTile) {
            var exactTiles = exactTilesByLoop[tile.loop] ?? []
            exactTiles.insert(tile.tile)
            exactTilesByLoop[tile.loop] = exactTiles

            var ancestorOrExactTiles = ancestorOrExactTilesByLoop[tile.loop] ?? []
            var ancestorX = tile.x
            var ancestorY = tile.y
            var ancestorZoom = tile.z

            while ancestorZoom >= 0 {
                ancestorOrExactTiles.insert(Tile(x: ancestorX, y: ancestorY, z: ancestorZoom))
                ancestorX >>= 1
                ancestorY >>= 1
                ancestorZoom -= 1
            }
            ancestorOrExactTilesByLoop[tile.loop] = ancestorOrExactTiles
        }
    }

    /// Maps relative distance to preferred demand zoom.
    ///
    /// Rules:
    /// - near: exact (`z`),
    /// - medium: one level coarser (`z-1`),
    /// - far: two levels coarser (`z-2`).
    private func preferredZoom(for visibleTile: VisibleTile, distance: Int) -> Int {
        if distance > deepCoarseRelativeDistanceThreshold {
            return max(0, visibleTile.z - 2)
        }
        if distance > coarseRelativeDistanceThreshold {
            return max(0, visibleTile.z - 1)
        }
        return visibleTile.z
    }

    /// Computes Chebyshev-like relative tile distance from map center.
    ///
    /// Backend semantics:
    /// - `spherical`: shortest wrapped distance on x-axis.
    /// - `flat`: linear world x with explicit loop shift.
    private func maxRelativeDistance(tile: VisibleTile,
                                     center: Center,
                                     renderSurfaceMode: ViewMode) -> Int {
        VisibleTileRelativeDistance.compute(tile: tile,
                                            center: center,
                                            renderSurfaceMode: renderSurfaceMode)
    }

    /// Returns target tile at requested zoom preserving source `loop`.
    ///
    /// Invariant:
    /// - `targetZoom == visibleTile.z` returns exact tile.
    /// - otherwise returns parent tile if ancestry exists, else `nil`.
    private func targetTile(for visibleTile: VisibleTile, targetZoom: Int) -> VisibleTile? {
        if targetZoom == visibleTile.z {
            return visibleTile
        }
        guard let parent = visibleTile.tile.findParentTile(atZoom: targetZoom) else {
            return nil
        }
        return VisibleTile(tile: parent, loop: visibleTile.loop)
    }

}
