// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The trees of a tile: the fills whose style grows them and the roads
/// they keep off are gathered as the layers are read, and the trees are
/// placed once every layer is in (`TreeScatter`), since they keep off the
/// buildings' footprints too and the buildings can come after the woods.
/// No tree below the tile zoom the trees draw from
/// (`TileParseOptions.treeMinimumSourceZoom`): a coarser tile carries
/// none, and gathers nothing.
struct TreeFeatureReader {
    private let options: TileParseOptions

    init(options: TileParseOptions) {
        self.options = options
    }

    /// Whether a tile of `tile` stands trees at all.
    func standsTrees(in tile: Tile) -> Bool {
        guard let minimumZoom = options.treeMinimumSourceZoom else { return false }
        return tile.z >= minimumZoom
    }

    /// A fill's polygons, kept for the scatter when the fill grows trees,
    /// and kept for the trees to keep off when it stands none
    /// (`FillStyle.excludesTrees`), on a tile deep enough to draw them.
    func collect(polygons: MultiPolygon,
                 fill: FillStyle,
                 tile: Tile,
                 into result: inout ReadingStageResult) {
        guard standsTrees(in: tile), polygons.isEmpty == false else {
            return
        }
        if let trees = fill.trees {
            result.treeAreas.append(TreeScatter.Area(polygons: polygons, style: trees))
        }
        if fill.excludesTrees {
            for polygon in polygons where polygon.exteriorRing.count >= 3 {
                result.treeExcludedFills.append(TreeScatter.Footprint(
                    exterior: Self.renderRing(polygon.exteriorRing),
                    interiors: polygon.interiorRings.map(Self.renderRing)))
            }
        }
    }

    private static func renderRing(_ ring: [Point]) -> [SIMD2<Float>] {
        ring.map { TileCoordinateSpace.renderPoint(SIMD2<Float>(Float($0.x), Float($0.y))) }
    }

    /// A mapped tree's points (`TreePointStyle`), kept to be planted with
    /// the fills' trees, on a tile deep enough to draw them. A point
    /// outside the tile is its neighbour's.
    func collect(points: MultiPoint,
                 tree: TreePointStyle,
                 tile: Tile,
                 into result: inout ReadingStageResult) {
        guard standsTrees(in: tile) else { return }
        let extent = TileCoordinateSpace.tileExtent
        for point in points {
            let tilePoint = SIMD2<Float>(Float(point.x), Float(point.y))
            guard tilePoint.x >= 0, tilePoint.x < extent, tilePoint.y >= 0, tilePoint.y < extent else { continue }
            result.mappedTrees.append(TreeScatter.MappedTree(tilePoint: tilePoint, style: tree))
        }
    }

    /// A road's lines, kept for the trees to keep off: the roads of the
    /// ground, as wide as the widest stroke the style draws them with,
    /// read as tile units of the lattice's zoom (`TreeScatter.Road`). A
    /// tunnel runs under the trees and a bridge over them.
    func collect(lines: MultiLineString,
                 road: RoadStyle,
                 tile: Tile,
                 into result: inout ReadingStageResult) {
        guard standsTrees(in: tile), road.level == .ground, lines.isEmpty == false else {
            return
        }
        let width = road.orderedPasses.map { Float($0.pass.lineGeometry.lineWidth) }.max() ?? 0
        for line in lines where line.count >= 2 {
            result.treeRoads.append(TreeScatter.Road(
                points: line.map { TileCoordinateSpace.renderPoint(SIMD2<Float>(Float($0.x), Float($0.y))) },
                halfWidth: max(width, 0) / 2))
        }
    }

    /// Places the tile's trees over the gathered fills, off the buildings'
    /// footprints in `footprints`, the gathered roads and the gathered
    /// fills no tree stands on, and the mapped trees at their points, the
    /// scattered ones off their crowns.
    func finish(tile: Tile,
                footprints: [TreeScatter.Footprint],
                into result: inout ReadingStageResult) {
        defer {
            result.treeAreas.removeAll()
            result.treeRoads.removeAll()
            result.treeExcludedFills.removeAll()
            result.mappedTrees.removeAll()
        }
        guard result.treeAreas.isEmpty == false || result.mappedTrees.isEmpty == false else { return }
        result.trees = TreeScatter.scatter(areas: result.treeAreas,
                                           mapped: result.mappedTrees,
                                           tile: tile,
                                           obstacles: TreeScatter.Obstacles(footprints: footprints + result.treeExcludedFills,
                                                                            roads: result.treeRoads),
                                           maximumCount: options.treeMaximumPerTile)
    }
}
