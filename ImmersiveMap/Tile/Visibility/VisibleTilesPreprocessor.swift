// Copyright (c) 2025-2026 ImmersiveMap contributors.
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
    /// перечислять тайлы дальше этого радиуса бессмысленно - фильтр их выбросит.
    ///
    /// Радиус определяет видимую дальность плоского представления: туман
    /// обязан насыщаться до кромки покрытия (`HorizonFogUniform`), поэтому
    /// короткий радиус буквально приближает горизонт. Кольцо дистанций за
    /// `farRingRelativeDistance` заполняется тайлами зума подложки (z3) из
    /// пиннинга мирового покрытия - дальность обзора почти утраивается ценой
    /// пары всегда резидентных тайлов.
    static let defaultMaxVisibleRelativeDistance = 40

    /// За этой дистанцией кольцо покрытия падает на абсолютный зум подложки
    /// (`TileCulling.flatBackdropZoomLevel`): тайлы z3 в пиннинге мирового
    /// покрытия, дальнее кольцо после прогрева не стоит ничего и совпадает по
    /// контенту с подложкой горизонта, поэтому граница радиуса не видна.
    /// В плоском режиме порог короче: даль агрессивно отдаётся подложке,
    /// чтобы срезать количество векторных тайлов.
    private static func farRingRelativeDistance(for renderSurfaceMode: ViewMode) -> Int {
        renderSurfaceMode == .flat ? 10 : 15
    }

    private let maxVisibleRelativeDistance: Int
    private let exactRelativeDistanceRadius: Int

    init(maxVisibleRelativeDistance: Int = VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance,
         exactRelativeDistanceRadius: Int = 2) {
        self.maxVisibleRelativeDistance = maxVisibleRelativeDistance
        self.exactRelativeDistanceRadius = max(1, exactRelativeDistanceRadius)
    }

    /// Runs the full preprocessing pipeline:
    /// 1) distance filter + preferred LOD stage,
    /// 2) deterministic priority sort,
    /// 3) non-overlapping coverage selection,
    /// 4) deterministic output sort.
    ///
    /// `transition` — фаза глобус→плоскость (0 — глобус, 1 — плоскость):
    /// управляет широтным LOD на сфере.
    func preprocess(visibleTiles: [VisibleTile],
                    center: Center,
                    renderSurfaceMode: ViewMode,
                    transition: Float) -> [VisibleTile] {
        let stagedInputs = buildStageInputs(visibleTiles: visibleTiles,
                                            center: center,
                                            renderSurfaceMode: renderSurfaceMode,
                                            transition: transition)
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
                                  renderSurfaceMode: ViewMode,
                                  transition: Float) -> [InputTile] {
        var inputs: [InputTile] = []
        inputs.reserveCapacity(visibleTiles.count)

        for visibleTile in visibleTiles {
            let distance = maxRelativeDistance(tile: visibleTile,
                                               center: center,
                                               renderSurfaceMode: renderSurfaceMode)
            guard distance <= maxVisibleRelativeDistance else {
                continue
            }
            let latitudeDrop = latitudeCoarseningDrop(for: visibleTile,
                                                      renderSurfaceMode: renderSurfaceMode,
                                                      transition: transition)
            inputs.append(InputTile(visibleTile: visibleTile,
                                    relativeDistance: distance,
                                    preferredZoom: preferredZoom(for: visibleTile,
                                                                 distance: distance,
                                                                 latitudeDrop: latitudeDrop,
                                                                 renderSurfaceMode: renderSurfaceMode)))
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

    /// Крутизна дистанционного LOD: 1.0 - честная перспектива (уровень на
    /// удвоение дистанции), выше - агрессивнее огрубление дали. Детализация
    /// у горизонта всё равно только мерцает при минификации, а тайлов на её
    /// покрытие уходит кратно больше. В плоском режиме крутизна выше: даль
    /// целиком декоративна, приоритет за количеством тайлов.
    private static func distanceLodSteepness(for renderSurfaceMode: ViewMode) -> Double {
        renderSurfaceMode == .flat ? 3.0 : 1.5
    }

    /// Кап суммарного дистанционного понижения: глубже z-4 даль не падает.
    private static let maximumDistanceDrop = 4

    /// Maps relative distance and latitude coarsening to preferred demand zoom.
    ///
    /// Экранный размер тайла в перспективе падает как 1/дистанция; лесенка
    /// идёт от точного радиуса 2. Сфера (крутизна 1.5): дистанция 3 → z-1,
    /// 4-5 → z-2, 6-8 → z-3, 9+ → z-4. Плоскость (крутизна 3.0): 3 → z-2,
    /// 4 → z-3, 5+ → z-4, а за порогом подложки кламп к z3.
    ///
    /// `latitudeDrop` добавляется к дистанционному понижению: оба эффекта
    /// (перспектива и меркаторное сжатие) уменьшают экранный размер тайла
    /// независимо.
    private func preferredZoom(for visibleTile: VisibleTile,
                               distance: Int,
                               latitudeDrop: Int,
                               renderSurfaceMode: ViewMode) -> Int {
        let distanceDrop = distanceCoarseningDrop(distance: distance, renderSurfaceMode: renderSurfaceMode)
        let ladderZoom = max(0, visibleTile.z - distanceDrop - latitudeDrop)
        guard distance > Self.farRingRelativeDistance(for: renderSurfaceMode) else {
            return ladderZoom
        }
        return min(ladderZoom, TileCulling.flatBackdropZoomLevel)
    }

    private func distanceCoarseningDrop(distance: Int, renderSurfaceMode: ViewMode) -> Int {
        guard distance > exactRelativeDistanceRadius else {
            return 0
        }

        let doublings = log2(Double(distance) / Double(exactRelativeDistanceRadius))
        let steepenedDrop = Int((doublings * Self.distanceLodSteepness(for: renderSurfaceMode)).rounded(.up))
        return min(Self.maximumDistanceDrop, steepenedDrop)
    }

    /// На сфере меркаторный тайл у полюса меньше экваторного в `cos(широты)` раз,
    /// поэтому приполярные тайлы понижаются на `log2(1/cos)` уровней: плотность
    /// покрытия на экран выравнивается с экваториальной. Широта берётся по краю
    /// тайла, ближайшему к экватору, — консервативная оценка сжатия.
    private func latitudeCoarseningDrop(for visibleTile: VisibleTile,
                                        renderSurfaceMode: ViewMode,
                                        transition: Float) -> Int {
        guard renderSurfaceMode == .spherical else {
            return 0
        }

        let tilesCount = Double(1 << visibleTile.z)
        let northEdgeY = Double(visibleTile.y) / tilesCount
        let southEdgeY = Double(visibleTile.y + 1) / tilesCount
        guard northEdgeY > 0.5 || southEdgeY < 0.5 else {
            return 0
        }

        let nearestToEquatorY = southEdgeY < 0.5 ? southEdgeY : northEdgeY
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: nearestToEquatorY)
        let surfaceScale = SurfaceScaleMath.surfaceScale(latitude: latitude, transition: transition)
        return max(0, Int(floor(-log2(surfaceScale))))
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
