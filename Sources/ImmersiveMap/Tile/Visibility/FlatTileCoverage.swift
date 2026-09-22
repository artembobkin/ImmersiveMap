// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The flat map's tile enumeration: the tiles of one zoom under a polygon
/// of the plane, every world copy, in a deterministic order. The ring
/// rules (`FlatRingRuleCoverage`) enumerate each band's ground with it.
enum FlatTileCoverage {
    private static let worldWraps: [Int8] = [-1, 0, 1]

    /// The tiles at `zoom` the polygon meets, every world copy, in a
    /// deterministic order.
    static func tiles(atZoom zoom: Int, polygon: CoveragePolygon, flatRenderState: FlatRenderState) -> [VisibleTile] {
        var visited = 0
        return tiles(atZoom: zoom, polygon: polygon, flatRenderState: flatRenderState, visited: &visited)
    }

    /// The same, counting the tiles looked at into `visited`.
    static func tiles(atZoom zoom: Int,
                      polygon: CoveragePolygon,
                      flatRenderState: FlatRenderState,
                      visited: inout Int) -> [VisibleTile] {
        guard zoom >= 0 else { return [] }
        var tiles: [VisibleTile] = []
        func visit(_ node: VisibleTile) {
            visited += 1
            guard Self.squareMeets(node, flatRenderState: flatRenderState, polygon: polygon) else { return }
            if node.z == zoom {
                tiles.append(node)
                return
            }
            for child in Self.children(of: node) {
                visit(child)
            }
        }
        for worldWrap in worldWraps {
            visit(VisibleTile(x: 0, y: 0, z: 0, worldWrap: worldWrap))
        }
        return tiles.sorted { lhs, rhs in
            if lhs.worldWrap != rhs.worldWrap { return lhs.worldWrap < rhs.worldWrap }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
    }

    /// Whether the polygon meets the tile's square in world units.
    private static func squareMeets(_ node: VisibleTile, flatRenderState: FlatRenderState, polygon: CoveragePolygon) -> Bool {
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: node.x, y: node.y, z: node.z, worldWrap: node.worldWrap,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        return polygon.intersects(minX: Double(origin.x),
                                  minY: Double(origin.y),
                                  maxX: Double(origin.x) + Double(origin.z),
                                  maxY: Double(origin.y) + Double(origin.z))
    }

    private static func children(of node: VisibleTile) -> [VisibleTile] {
        let x = node.x * 2
        let y = node.y * 2
        let z = node.z + 1
        return [VisibleTile(x: x, y: y, z: z, worldWrap: node.worldWrap),
                VisibleTile(x: x + 1, y: y, z: z, worldWrap: node.worldWrap),
                VisibleTile(x: x, y: y + 1, z: z, worldWrap: node.worldWrap),
                VisibleTile(x: x + 1, y: y + 1, z: z, worldWrap: node.worldWrap)]
    }

    /// Renderer-stable order: finest first, then by world copy and position.
    static func sorted(_ targets: [VisibleTile]) -> [VisibleTile] {
        targets.sorted { lhs, rhs in
            if lhs.z != rhs.z { return lhs.z > rhs.z }
            if lhs.worldWrap != rhs.worldWrap { return lhs.worldWrap < rhs.worldWrap }
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
    }
}
