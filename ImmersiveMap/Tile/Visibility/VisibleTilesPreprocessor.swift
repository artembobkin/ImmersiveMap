// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  VisibleTilesPreprocessor.swift
//  ImmersiveMap
//

import Foundation

/// Optimizes visible tile instances after culling: filters too-distant
/// tiles and applies coarse LOD substitution. On the plane the coverage is
/// `FlatDistanceCoverage`: every tile's zoom follows its distance from the
/// eye, overlaps allowed (the tile-priority stencil lets the finest painter
/// own each pixel), the farthest parents trimmed to a ceiling. On the
/// sphere the same distance rule (`GlobeDistanceCoverage`) sets each
/// tile's preferred zoom, with the pinned world cover standing in for
/// the far field, and a non-overlapping selection follows; without a
/// globe camera (a tile-free test) the sphere falls back to its grid
/// ladder.
///
/// Invariants:
/// - The sphere's output contains no overlapping targets inside the same
///   `loop`; the plane's output holds at most
///   `FlatDistanceCoverage.maximumParents` parents when a backdrop exists,
///   plus the exact tiles within the exact radius.
/// - Output ordering is deterministic (`z desc`, then `loop/x/y asc`).
/// - The preprocessor never creates tiles outside source ancestry:
///   each selected tile is the input tile itself or one of its parents.
final class VisibleTilesPreprocessor {
    /// Distance-filter radius (Chebyshev, in tiles of the target zoom).
    /// The candidate clamp in `FlatVisibleTileResolver` relies on it too:
    /// enumerating tiles beyond this radius is pointless - the filter drops them.
    ///
    /// The radius defines the visible range of the spherical presentation: a
    /// short radius literally pulls the horizon closer. In flat mode the far
    /// range is not limited by the radius: a tile whose parent would be the
    /// backdrop's zoom is handed to the solid z3 horizon backdrop
    /// (`TileCulling.resolveFlatBackdropTiles`) long before it.
    static let defaultMaxVisibleRelativeDistance = 40

    /// The sphere's grid ladder, used only without a globe camera: beyond
    /// this distance the far range stops being honest coverage of the
    /// target ladder and preference falls to the pinned world cover's zoom
    /// (`TileCulling.flatBackdropZoomLevel`).
    private static let sphereFarRingRelativeDistance = 15

    private let maxVisibleRelativeDistance: Int
    private let exactRelativeDistanceRadius: Int
    /// The flat map's coverage rule, with its per-tile level memory.
    private let flatCoverage = FlatDistanceCoverage()
    /// The sphere's coverage rule, with its own level memory.
    private let globeCoverage = GlobeDistanceCoverage()

    init(maxVisibleRelativeDistance: Int = VisibleTilesPreprocessor.defaultMaxVisibleRelativeDistance,
         exactRelativeDistanceRadius: Int = 2) {
        self.maxVisibleRelativeDistance = maxVisibleRelativeDistance
        self.exactRelativeDistanceRadius = max(1, exactRelativeDistanceRadius)
    }

    /// Runs the full preprocessing pipeline:
    /// 1) distance filter,
    /// 2) on the plane: the distance rule (`FlatDistanceCoverage`); on the
    ///    sphere: the preferred LOD stage, deterministic priority sort and
    ///    non-overlapping coverage selection,
    /// 3) deterministic output sort.
    ///
    /// `flatCamera` is the flat camera's eye and ground points; without one
    /// on the plane every tile is asked for exactly, which is what the flat
    /// cases of a tile-free test want and what the sphere never passes.
    /// `globeCamera` is the sphere's eye and globe; without one the sphere
    /// uses its grid ladder.
    func preprocess(visibleTiles: [VisibleTile],
                    center: Center,
                    renderSurfaceMode: ViewMode,
                    flatCamera: FlatCoverageCamera? = nil,
                    globeCamera: GlobeCoverageCamera? = nil) -> [VisibleTile] {
        switch renderSurfaceMode {
        case .flat:
            let inRange = visibleTiles.filter { tile in
                maxRelativeDistance(tile: tile, center: center, renderSurfaceMode: renderSurfaceMode) <= maxVisibleRelativeDistance
            }
            guard let flatCamera else {
                return sortTargetsForOutput(Set(inRange))
            }
            let targets = flatCoverage.targets(visibleTiles: inRange,
                                               camera: flatCamera,
                                               backdropZoom: flatCamera.backdropZoom)
            return sortTargetsForOutput(Set(targets))
        case .spherical:
            let stagedInputs = buildStageInputs(visibleTiles: visibleTiles,
                                                center: center,
                                                renderSurfaceMode: renderSurfaceMode,
                                                globeCamera: globeCamera)
            let selectedTargets = selectCoverageTargets(from: sortInputsForSelection(stagedInputs))
            return sortTargetsForOutput(selectedTargets)
        }
    }

    /// Builds the sphere's candidate inputs for selection.
    ///
    /// Invariants:
    /// - Every emitted `InputTile` has `relativeDistance <= maxVisibleRelativeDistance`.
    /// - `preferredZoom` is clamped to `[0...visibleTile.z]`.
    private func buildStageInputs(visibleTiles: [VisibleTile],
                                  center: Center,
                                  renderSurfaceMode: ViewMode,
                                  globeCamera: GlobeCoverageCamera?) -> [InputTile] {
        var inRange: [VisibleTile] = []
        var distances: [Int] = []
        inRange.reserveCapacity(visibleTiles.count)
        distances.reserveCapacity(visibleTiles.count)
        for visibleTile in visibleTiles {
            let distance = maxRelativeDistance(tile: visibleTile,
                                               center: center,
                                               renderSurfaceMode: renderSurfaceMode)
            guard distance <= maxVisibleRelativeDistance else {
                continue
            }
            inRange.append(visibleTile)
            distances.append(distance)
        }

        let preferredZooms: [Int]
        if let globeCamera {
            preferredZooms = globeCoverage.preferredZooms(visibleTiles: inRange, camera: globeCamera)
        } else {
            preferredZooms = inRange.indices.map { spherePreferredZoom(for: inRange[$0], distance: distances[$0]) }
        }

        var inputs: [InputTile] = []
        inputs.reserveCapacity(inRange.count)
        for index in inRange.indices {
            inputs.append(InputTile(visibleTile: inRange[index],
                                    relativeDistance: distances[index],
                                    preferredZoom: preferredZooms[index]))
        }
        return inputs
    }

    /// Orders the sphere's candidates for greedy selection.
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

    /// Greedily builds the sphere's coverage set with overlap exclusion.
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

    /// The grid ladder's steepness (the sphere without a globe camera): 1.0 would be honest perspective
    /// (one level per distance doubling); 1.5 coarsens the far range more,
    /// since detail near the limb only shimmers under minification anyway
    /// while covering it costs many times more tiles.
    private static let sphereDistanceLodSteepness = 1.5

    /// Cap on the sphere's distance drop: the far range never falls below z-4.
    private static let maximumDistanceDrop = 4

    /// The grid ladder's preferred demand zoom from relative distance, the
    /// sphere's rule when no globe camera is given.
    ///
    /// A tile's on-screen size in perspective falls as 1/distance; the ladder
    /// starts from the exact radius of 2: distance 3 → z-1, 4-5 → z-2,
    /// 6-8 → z-3, 9+ → z-4, beyond the ring threshold clamp to z3.
    ///
    /// No latitude term: the Mercator compression near the poles is
    /// answered by the camera moving in (`GlobeCameraProximity`), so the
    /// frustum holds the same number of tiles at every latitude.
    private func spherePreferredZoom(for visibleTile: VisibleTile,
                                     distance: Int) -> Int {
        let ladderZoom = max(0, visibleTile.z - sphereDistanceCoarseningDrop(distance: distance))
        guard distance > Self.sphereFarRingRelativeDistance else {
            return ladderZoom
        }
        return min(ladderZoom, TileCulling.flatBackdropZoomLevel)
    }

    private func sphereDistanceCoarseningDrop(distance: Int) -> Int {
        guard distance > exactRelativeDistanceRadius else {
            return 0
        }

        let doublings = log2(Double(distance) / Double(exactRelativeDistanceRadius))
        let steepenedDrop = Int((doublings * Self.sphereDistanceLodSteepness).rounded(.up))
        return min(Self.maximumDistanceDrop, steepenedDrop)
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
