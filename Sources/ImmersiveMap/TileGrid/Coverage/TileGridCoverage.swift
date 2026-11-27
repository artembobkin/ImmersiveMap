// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The tiles of one zoom the grid draws: those in view, the nearest to
/// where the camera looks first, and no more than a limit. The map's own
/// coverage (`FlatTileCoverage`, `GlobeTileCoverage`) answers another
/// question, which of its tiles to load, by the ring rules and without a
/// bound: under a camera tilted to the horizon the tiles of a deep zoom in
/// view are without number, so the grid walks the tree nearest first and
/// stops at its limit. What shows is decided by the same tests as the
/// map's: the frustum's footprint on the plane, the frustum and the
/// horizon on the sphere.
enum TileGridCoverage {
    enum Verdict {
        /// Nothing of the tile shows.
        case reject
        /// Some of the tile may show: its children are asked.
        case descend
        /// All of the tile shows: nothing under it is asked again.
        case acceptSubtree
    }

    /// The world copies the flat map draws.
    private static let worldWraps: [Int8] = [-1, 0, 1]

    // MARK: - The surfaces

    /// The tiles of `zoom` under the camera on the flat map, in every copy
    /// of the world in view.
    static func flat(zoom: Int,
                     limit: Int,
                     polygon: CoveragePolygon,
                     flatRenderState: FlatRenderState,
                     centre: SIMD2<Double>) -> [VisibleTile] {
        nearest(zoom: zoom,
                       limit: limit,
                       roots: worldWraps.map { VisibleTile(x: 0, y: 0, z: 0, worldWrap: $0) },
                       centre: centre,
                       wrapsRound: false) { node in
            squareMeets(node, polygon: polygon, flatRenderState: flatRenderState) ? .descend : .reject
        }
    }

    /// Whether the frustum's footprint on the plane (`CoveragePolygon`)
    /// meets a tile's square.
    private static func squareMeets(_ node: VisibleTile, polygon: CoveragePolygon, flatRenderState: FlatRenderState) -> Bool {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: node.x, y: node.y, z: node.z,
                                                                  worldWrap: node.worldWrap,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        return polygon.intersects(minX: Double(origin.x),
                                  minY: Double(origin.y),
                                  maxX: Double(origin.x) + Double(origin.z),
                                  maxY: Double(origin.y) + Double(origin.z))
    }

    /// The tiles of `zoom` in view on the sphere and through the unfurl.
    static func globe(zoom: Int,
                      limit: Int,
                      inputs: GlobeVisibilityInputs,
                      frustum: Frustum,
                      centre: SIMD2<Double>) -> [VisibleTile] {
        // Through the unfurl at the coarse zooms the visibility tests do
        // not hold, and the map takes every tile (`GlobeTileCoverage`).
        let takesAll = inputs.transition > 0 && zoom <= GlobeTileCoverage.transitionLowZoomFallbackLimit
        return nearest(zoom: zoom,
                       limit: limit,
                       roots: [VisibleTile(x: 0, y: 0, z: 0)],
                       centre: centre,
                       wrapsRound: true) { node in
            if takesAll { return .acceptSubtree }
            switch GlobeTileCoverage.evaluateVisibility(for: node.tile, targetZoom: zoom, frustum: frustum, inputs: inputs) {
            case .rejectFrustum, .rejectHorizon: return .reject
            case .descend: return .descend
            case .acceptWholeSubtree: return .acceptSubtree
            }
        }
    }

    // MARK: - One tile

    /// The copies of the world a tile shows in on the flat map, none when
    /// it is out of view.
    static func flatCopies(showing tile: Tile,
                           polygon: CoveragePolygon,
                           flatRenderState: FlatRenderState) -> [VisibleTile] {
        worldWraps.compactMap { worldWrap in
            let node = VisibleTile(tile: tile, worldWrap: worldWrap)
            return squareMeets(node, polygon: polygon, flatRenderState: flatRenderState) ? node : nil
        }
    }

    /// Whether a tile shows on the sphere or through the unfurl.
    static func globeShows(_ tile: Tile,
                           inputs: GlobeVisibilityInputs,
                           frustum: Frustum) -> Bool {
        if inputs.transition > 0, tile.z <= GlobeTileCoverage.transitionLowZoomFallbackLimit { return true }
        switch GlobeTileCoverage.evaluateVisibility(for: tile, targetZoom: tile.z,
                                                    frustum: frustum, inputs: inputs) {
        case .rejectFrustum, .rejectHorizon: return false
        case .descend, .acceptWholeSubtree: return true
        }
    }

    // MARK: - The walk

    /// The tiles of `zoom` under `roots` that `test` lets through, the
    /// nearest to `centre` (normalized world mercator, in the world's own
    /// copy) first, `limit` at most. A tile is no nearer than the tile
    /// that holds it, so the tree is walked best first and the first
    /// `limit` tiles reached are the nearest. `wrapsRound`: the world
    /// closes round the antimeridian (the sphere), so a tile across it is
    /// near.
    static func nearest(zoom: Int,
                        limit: Int,
                        roots: [VisibleTile],
                        centre: SIMD2<Double>,
                        wrapsRound: Bool,
                        test: (VisibleTile) -> Verdict) -> [VisibleTile] {
        guard zoom >= 0, limit > 0 else { return [] }
        var heap = Heap()
        func offer(_ node: VisibleTile, accepted: Bool) {
            var accepted = accepted
            if accepted == false {
                switch test(node) {
                case .reject: return
                case .descend: break
                case .acceptSubtree: accepted = true
                }
            }
            heap.push(Heap.Entry(distance: distanceSquared(from: centre, to: node, wrapsRound: wrapsRound),
                                 node: node,
                                 accepted: accepted))
        }
        for root in roots {
            offer(root, accepted: false)
        }

        var tiles: [VisibleTile] = []
        tiles.reserveCapacity(min(limit, 1024))
        // A bound on the walk itself, for a view that rejects nearly every
        // tile it reaches.
        var budget = limit * 64 + 4096
        while tiles.count < limit, budget > 0, let entry = heap.pop() {
            budget -= 1
            let node = entry.node
            if node.z == zoom {
                tiles.append(node)
                continue
            }
            let x = node.x * 2
            let y = node.y * 2
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                offer(VisibleTile(x: x + dx, y: y + dy, z: node.z + 1, worldWrap: node.worldWrap),
                      accepted: entry.accepted)
            }
        }
        return tiles
    }

    /// How far `centre` is from the nearest point of a tile's square, in
    /// the normalized world, squared.
    static func distanceSquared(from centre: SIMD2<Double>, to node: VisibleTile, wrapsRound: Bool) -> Double {
        let size = 1 / Double(1 << node.z)
        let minX = Double(node.x) * size + Double(node.worldWrap)
        let minY = Double(node.y) * size
        func alongX(_ x: Double) -> Double { max(minX - x, 0, x - (minX + size)) }
        var dx = alongX(centre.x)
        if wrapsRound {
            dx = min(dx, alongX(centre.x - 1), alongX(centre.x + 1))
        }
        let dy = max(minY - centre.y, 0, centre.y - (minY + size))
        return dx * dx + dy * dy
    }

    /// A binary heap of the walk's nodes, the nearest on top.
    private struct Heap {
        struct Entry {
            let distance: Double
            let node: VisibleTile
            let accepted: Bool
        }

        private var entries: [Entry] = []

        mutating func push(_ entry: Entry) {
            entries.append(entry)
            var index = entries.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard entries[index].distance < entries[parent].distance else { break }
                entries.swapAt(index, parent)
                index = parent
            }
        }

        mutating func pop() -> Entry? {
            guard let top = entries.first else { return nil }
            let last = entries.removeLast()
            guard entries.isEmpty == false else { return top }
            entries[0] = last
            var index = 0
            while true {
                let left = index * 2 + 1
                let right = left + 1
                var smallest = index
                if left < entries.count, entries[left].distance < entries[smallest].distance { smallest = left }
                if right < entries.count, entries[right].distance < entries[smallest].distance { smallest = right }
                guard smallest != index else { break }
                entries.swapAt(index, smallest)
                index = smallest
            }
            return top
        }
    }
}
