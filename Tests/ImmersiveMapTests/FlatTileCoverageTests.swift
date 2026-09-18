// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The flat map's tile enumeration: the tiles of one zoom under a polygon,
/// which the bands and the horizon backdrop are built from.
final class FlatTileCoverageTests: XCTestCase {
    /// A z9 world whose tiles are one world unit wide, so distances read in
    /// tiles.
    private static let zoom = 9
    private static let flatRenderState = FlatRenderState(pan: .zero, renderMapSize: Double(1 << zoom))
    private static let lookAt = SIMD2<Double>(256.5, 250.5)

    /// The world position of a point in tile units (tile y grows south,
    /// world y north).
    private static func world(ofTilePoint point: SIMD2<Double>) -> SIMD2<Double> {
        let x = Int(floor(point.x))
        let y = Int(floor(point.y))
        let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: x, y: y, z: zoom, worldWrap: 0,
                                                                  flatRenderPan: flatRenderState.pan,
                                                                  renderMapSize: flatRenderState.renderMapSize)
        let size = Double(origin.z)
        return SIMD2<Double>(Double(origin.x) + (point.x - Double(x)) * size,
                             Double(origin.y) + (1 - (point.y - Double(y))) * size)
    }

    /// The ground a square 45 degree frustum sees from a camera 1.2 tiles
    /// from the look-at point at `tilt` degrees, as the convex wedge the
    /// enumeration tests tiles against.
    private static func polygon(tilt: Double, reach: Double = 40) -> CoveragePolygon {
        let distance = 1.2
        let forward = SIMD2<Double>(0, -1)
        let right = SIMD2<Double>(1, 0)
        let eyeGround = lookAt - forward * (distance * sin(tilt * .pi / 180))
        func halfWidth(_ ahead: Double) -> Double { ahead * tan(Double.pi / 8) + 0.5 }
        let near = 0.25
        let nearCenter: SIMD2<Double> = eyeGround + forward * near
        let farCenter: SIMD2<Double> = eyeGround + forward * reach
        let nearSide: SIMD2<Double> = right * halfWidth(near)
        let farSide: SIMD2<Double> = right * halfWidth(reach)
        let corners: [SIMD2<Double>] = [nearCenter - nearSide, nearCenter + nearSide, farCenter + farSide, farCenter - farSide]
        return CoveragePolygon(vertices: corners.map { SIMD2<Float>(world(ofTilePoint: $0)) })
    }

    /// The leaves the polygon meets, column by column.
    private static func leaves(in polygon: CoveragePolygon) -> [VisibleTile] {
        let state = flatRenderState
        let tileSize = state.renderMapSize / Double(1 << zoom)
        let half = state.renderMapSize / 2
        let minColumn = Int(floor((Double(polygon.bounds.minX) + half) / tileSize)) - 1
        let maxColumn = Int(floor((Double(polygon.bounds.maxX) + half) / tileSize)) + 1
        let minRow = Int(floor((half - Double(polygon.bounds.maxY)) / tileSize)) - 1
        let maxRow = Int(floor((half - Double(polygon.bounds.minY)) / tileSize)) + 1
        var tiles: [VisibleTile] = []
        for y in minRow ... maxRow {
            for x in minColumn ... maxColumn {
                let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: x, y: y, z: zoom, worldWrap: 0,
                                                                          flatRenderPan: state.pan, renderMapSize: state.renderMapSize)
                if polygon.intersects(minX: Double(origin.x), minY: Double(origin.y),
                                      maxX: Double(origin.x) + Double(origin.z), maxY: Double(origin.y) + Double(origin.z)) {
                    tiles.append(VisibleTile(x: x, y: y, z: zoom))
                }
            }
        }
        return tiles
    }

    private static func cover(of tile: VisibleTile, in output: [VisibleTile]) -> VisibleTile? {
        output.first { $0.worldWrap == tile.worldWrap && ($0.tile == tile.tile || $0.tile.covers(tile.tile)) }
    }

    /// The enumeration at the leaves' own zoom is the leaves the polygon
    /// meets, each once, in a stable order.
    func testTheEnumerationAtAZoomIsTheTilesThePolygonMeets() {
        let polygon = Self.polygon(tilt: 75)
        let tiles = FlatTileCoverage.tiles(atZoom: Self.zoom, polygon: polygon, flatRenderState: Self.flatRenderState)
        XCTAssertEqual(Set(tiles), Set(Self.leaves(in: polygon)))
        XCTAssertEqual(Set(tiles).count, tiles.count)
        XCTAssertEqual(tiles, FlatTileCoverage.tiles(atZoom: Self.zoom, polygon: polygon, flatRenderState: Self.flatRenderState),
                       "deterministic")
    }

    /// The backdrop is the coarse tiles under the whole footprint, in a
    /// stable order, every leaf under one of them.
    func testTheBackdropEnumeratesTheFootprintAtItsZoom() {
        let polygon = Self.polygon(tilt: 75)
        var visited = 0
        let backdrop = FlatTileCoverage.tiles(atZoom: 3, polygon: polygon, flatRenderState: Self.flatRenderState, visited: &visited)
        XCTAssertFalse(backdrop.isEmpty)
        XCTAssertGreaterThan(visited, backdrop.count)
        XCTAssertTrue(backdrop.allSatisfy { $0.z == 3 })
        for leaf in Self.leaves(in: polygon) {
            XCTAssertNotNil(Self.cover(of: leaf, in: backdrop), "\(leaf) is under a backdrop tile")
        }
        XCTAssertEqual(backdrop, FlatTileCoverage.tiles(atZoom: 3, polygon: polygon, flatRenderState: Self.flatRenderState),
                       "deterministic")
    }

    /// The renderer's order: finest first, then by world copy and position.
    func testTheSortIsFinestFirst() {
        let sorted = FlatTileCoverage.sorted([VisibleTile(x: 1, y: 1, z: 3),
                                              VisibleTile(x: 0, y: 0, z: 5, worldWrap: 1),
                                              VisibleTile(x: 0, y: 0, z: 5),
                                              VisibleTile(x: 2, y: 0, z: 3)])
        XCTAssertEqual(sorted, [VisibleTile(x: 0, y: 0, z: 5),
                                VisibleTile(x: 0, y: 0, z: 5, worldWrap: 1),
                                VisibleTile(x: 1, y: 1, z: 3),
                                VisibleTile(x: 2, y: 0, z: 3)])
    }
}
