// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import simd
import XCTest

final class TreeScatterTests: XCTestCase {
    private let style = TreeFillStyle(spacingMetres: 20, heightMetres: 8 ... 8, roadClearanceMetres: 0)

    /// A polygon over the whole tile.
    private var wholeTile: Mvt.Polygon {
        let extent = Int32(TileCoordinateSpace.tileExtentInt)
        return Mvt.Polygon(exteriorRing: [Mvt.Point(x: 0, y: 0), Mvt.Point(x: extent, y: 0),
                                      Mvt.Point(x: extent, y: extent), Mvt.Point(x: 0, y: extent)],
                       interiorRings: [])
    }

    /// A tree's point in the world, in the tile units of the lattice's
    /// zoom, from its render space position in a tile.
    private func worldPoints(of trees: [TreeInstance], tile: Tile) -> [SIMD2<Double>] {
        let scale = pow(2.0, Double(TreeScatter.latticeZoom - tile.z))
        let extent = TileCoordinateSpace.tileExtentDouble
        return trees.map { tree in
            let tileY = extent - Double(tree.position.y)
            return SIMD2<Double>((Double(tile.x) * extent + Double(tree.position.x)) * scale,
                                 (Double(tile.y) * extent + tileY) * scale)
        }
    }

    /// A road across a tile in render space: a diagonal from the south
    /// west corner to the north east one, in the tile's own units, so
    /// the parent's and each child's lie on one line on the ground.
    private func diagonalRoad(across tile: Tile, parent: Tile) -> TreeScatter.Road {
        // The parent's diagonal, cut to the child's square.
        let scale = Float(pow(2.0, Double(tile.z - parent.z)))
        let extent = TileCoordinateSpace.tileExtent
        let originX = Float(tile.x - parent.x * Int(scale)) * extent
        let originY = Float(tile.y - parent.y * Int(scale)) * extent
        // In the parent's units the diagonal is y = x (tile space). A
        // point of the child at (x, y) in its units lies at
        // (originX + x, originY + y) / scale in the parent's.
        let start = SIMD2<Float>(-originX, -originY)
        let end = start + SIMD2<Float>(repeating: extent * scale)
        return TreeScatter.Road(points: [TileCoordinateSpace.renderPoint(start), TileCoordinateSpace.renderPoint(end)],
                                halfWidth: 60)
    }

    /// The trees of a tile are the trees of its children, at the same
    /// points, a road across them keeping the same ones off: the coverage
    /// draws the one or the others for the same ground, and a move of
    /// the camera must not change a wood.
    func testAParentTileStandsTheSameTreesAsItsChildren() {
        let parent = Tile(x: 9903, y: 5120, z: 14)
        let parentTrees = TreeScatter.scatter(areas: [TreeScatter.Area(polygons: [wholeTile], style: style)],
                                              tile: parent,
                                              obstacles: TreeScatter.Obstacles(roads: [diagonalRoad(across: parent, parent: parent)]),
                                              maximumCount: 100_000)
        XCTAssertGreaterThan(parentTrees.count, 1_000)

        var childPoints: [SIMD2<Double>] = []
        var childHeights: [Float] = []
        for dy in 0 ... 1 {
            for dx in 0 ... 1 {
                let child = Tile(x: parent.x * 2 + dx, y: parent.y * 2 + dy, z: 15)
                let trees = TreeScatter.scatter(areas: [TreeScatter.Area(polygons: [wholeTile], style: style)],
                                                tile: child,
                                                obstacles: TreeScatter.Obstacles(roads: [diagonalRoad(across: child, parent: parent)]),
                                                maximumCount: 100_000)
                childPoints += worldPoints(of: trees, tile: child)
                // The child's units are twice the parent's: the heights
                // compare in the parent's.
                childHeights += trees.map { $0.height / 2 }
            }
        }
        let parentPoints = worldPoints(of: parentTrees, tile: parent)
        XCTAssertEqual(parentPoints.count, childPoints.count)

        func sorted(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
            points.sorted { lhs, rhs in lhs.x != rhs.x ? lhs.x < rhs.x : lhs.y < rhs.y }
        }
        let parentSorted = sorted(parentPoints)
        let childSorted = sorted(childPoints)
        var mismatches = 0
        for (lhs, rhs) in zip(parentSorted, childSorted) where simd_length(lhs - rhs) > 0.5 {
            mismatches += 1
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches) of \(parentPoints.count) trees stand elsewhere in the children")

        let parentHeights = parentTrees.map { $0.height }.sorted()
        for (lhs, rhs) in zip(parentHeights, childHeights.sorted()) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.01)
        }
    }

    /// The same tile grows the same trees at every parse.
    func testTheScatterIsDeterministic() {
        let tile = Tile(x: 19806, y: 10241, z: 15)
        let area = TreeScatter.Area(polygons: [wholeTile], style: style)
        let first = TreeScatter.scatter(areas: [area], tile: tile, obstacles: TreeScatter.Obstacles(), maximumCount: 500)
        let second = TreeScatter.scatter(areas: [area], tile: tile, obstacles: TreeScatter.Obstacles(), maximumCount: 500)
        XCTAssertEqual(first.count, 500)
        XCTAssertEqual(first, second)
    }
}
