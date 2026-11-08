// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A tile coarser than the tileset's deepest zoom keeps its buildings and
/// its trees by quarters, the squares of its four children, so the frame
/// draws a quarter where the child is not there to: the quarters' layout,
/// the parse that cuts the volumes at their edges, and what the drawers
/// read of them.
final class TileQuartersTests: XCTestCase {
    private let extent = TileCoordinateSpace.tileExtent

    /// A quarter is numbered by where it lies in tile space (y south), and
    /// its child is the tile one zoom finer over the same square.
    func testAQuarterIsTheSquareOfOneChild() {
        let half = extent / 2
        XCTAssertEqual(TileQuarters.quarter(ofTilePoint: SIMD2<Float>(10, 10)), 0, "North-west")
        XCTAssertEqual(TileQuarters.quarter(ofTilePoint: SIMD2<Float>(half + 10, 10)), 1, "North-east")
        XCTAssertEqual(TileQuarters.quarter(ofTilePoint: SIMD2<Float>(10, half + 10)), 2, "South-west")
        XCTAssertEqual(TileQuarters.quarter(ofTilePoint: SIMD2<Float>(half, half)), 3, "An edge goes east and south")
        XCTAssertEqual(TileQuarters.quarter(ofRenderPoint: SIMD2<Float>(10, extent - 10)), 0, "Render space is y north")

        let tile = Tile(x: 9908, y: 5140, z: 14)
        XCTAssertEqual(TileQuarters.child(of: tile, quarter: 0), Tile(x: 19816, y: 10280, z: 15))
        XCTAssertEqual(TileQuarters.child(of: tile, quarter: 3), Tile(x: 19817, y: 10281, z: 15))
        XCTAssertEqual(TileQuarters.square(of: 3).minimum, SIMD2<Float>(half, half))
        XCTAssertEqual(TileQuarters.square(of: 3).maximum, SIMD2<Float>(extent, extent))
    }

    /// The runs a mask draws: consecutive quarters joined, empty quarters
    /// skipped, and a tile kept whole drawn whole or not at all.
    func testTheRunsOfAMask() {
        let starts = [0, 6, 6, 18, 30]
        XCTAssertEqual(TileQuarters.runs(starts: starts, whole: 0..<30, mask: TileQuarters.all), [0..<30])
        XCTAssertEqual(TileQuarters.runs(starts: starts, whole: 0..<30, mask: 0b1001), [0..<6, 18..<30])
        XCTAssertEqual(TileQuarters.runs(starts: starts, whole: 0..<30, mask: 0b0010), [], "An empty quarter")
        XCTAssertEqual(TileQuarters.runs(starts: [], whole: 0..<30, mask: TileQuarters.all), [0..<30])
        XCTAssertEqual(TileQuarters.runs(starts: [], whole: 0..<30, mask: 0b0011), [], "A whole tile has no quarter")
    }

    /// The tiles coarser than the tileset's deepest zoom keep quarters,
    /// from the buildings' zoom on: with the default tileset, zoom 14.
    func testTheTilesThatKeepQuarters() {
        let options = TileParseOptions(settings: .default)
        XCTAssertEqual(options.buildingDeepestSourceZoom, 15)
        XCTAssertFalse(options.keepsQuarters(tileZoom: 13), "No buildings")
        XCTAssertTrue(options.keepsQuarters(tileZoom: 14))
        XCTAssertFalse(options.keepsQuarters(tileZoom: 15), "The deepest tiles have no children with buildings")
    }

    /// A zoom 14 tile cuts a volume that crosses a quarter's edge into a
    /// piece in each quarter, lays the pieces out quarter by quarter, and
    /// keeps where each quarter starts, every start even. A zoom 15 tile
    /// keeps its volume whole.
    func testAZoom14TileCutsItsVolumesAtTheQuartersEdges() throws {
        // One building across the north quarters' edge, x 1536 to 2560,
        // one in the south-east.
        let across: [(Int32, Int32)] = [(1536, 512), (2560, 512), (2560, 1024), (1536, 1024)]
        let southEast: [(Int32, Int32)] = [(2560, 2560), (3072, 2560), (3072, 3072), (2560, 3072)]
        let data = VectorTileFixture.layerTile(layerName: "buildings", features: [
            .building(id: 1, ring: across, height: "30"),
            .building(id: 2, ring: southEast, height: "12")
        ])
        let parser = TileMvtParser.forTests(settings: .default)

        let quartered = try parser.parse(tile: Tile(x: 9908, y: 5140, z: 14), mvtData: data).drawingExtruded
        let starts = quartered.quarterIndexStarts.map(Int.init)
        XCTAssertEqual(starts.count, 5)
        XCTAssertEqual(starts.first, 0)
        XCTAssertEqual(starts.last, quartered.indices.count)
        XCTAssertTrue(starts.allSatisfy { $0 % 2 == 0 }, "Each quarter starts at an even index: \(starts)")
        XCTAssertEqual(starts[3], starts[2], "Nothing in the south-west")
        // The first building has a range in each northern quarter, the
        // second one in the south-east.
        let first = quartered.buildingRanges.filter { $0.featureID == 1 }
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.contains { Int($0.indexStart) >= starts[0] && Int($0.indexStart) < starts[1] })
        XCTAssertTrue(first.contains { Int($0.indexStart) >= starts[1] && Int($0.indexStart) < starts[2] })
        let second = try XCTUnwrap(quartered.buildingRanges.first { $0.featureID == 2 })
        XCTAssertGreaterThanOrEqual(Int(second.indexStart), starts[3])
        // Every vertex of a quarter's volumes lies in that quarter.
        for quarter in 0..<TileQuarters.count {
            for index in quartered.indices[starts[quarter]..<starts[quarter + 1]] {
                let vertex = quartered.vertices[Int(index)]
                let position = SIMD2<Float>(Float(vertex.positionX), Float(vertex.positionY)) / ExtrudedVertexIn.positionScale
                let square = TileQuarters.square(of: quarter)
                let tilePoint = TileCoordinateSpace.renderPoint(position)
                XCTAssertTrue(tilePoint.x >= square.minimum.x - 1 && tilePoint.x <= square.maximum.x + 1
                              && tilePoint.y >= square.minimum.y - 1 && tilePoint.y <= square.maximum.y + 1,
                              "A vertex of quarter \(quarter) at \(tilePoint)")
            }
        }

        let whole = try parser.parse(tile: Tile(x: 19816, y: 10280, z: 15), mvtData: data).drawingExtruded
        XCTAssertTrue(whole.quarterIndexStarts.isEmpty)
        XCTAssertEqual(whole.buildingRanges.filter { $0.featureID == 1 }.count, 1, "Whole")
    }

    /// A quartered tile's trees go quarter by quarter, each quarter's in
    /// the priority order they had.
    func testTheTreesGoQuarterByQuarterInTheirOrder() {
        let half = extent / 2
        func tree(_ x: Float, _ y: Float, _ height: Float) -> TreeInstance {
            TreeInstance(position: SIMD2<Float>(x, y), height: height, rotation: 0, tint: 0)
        }
        // Render space, y north: a high y is the north.
        let trees = [tree(half + 10, half + 10, 1), tree(10, 10, 2), tree(10, half + 10, 3), tree(half + 20, half + 20, 4)]
        let (ordered, starts) = TreeFeatureReader.byQuarter(trees)
        XCTAssertEqual(ordered.map(\.height), [3, 1, 4, 2])
        XCTAssertEqual(starts, [0, 1, 3, 3, 4])
    }

    /// The trees a placement draws: a prefix of each quarter it draws, cut
    /// by the zoom's share, at least one of a quarter that has any.
    func testTheTreesOfTheQuartersDrawn() {
        let starts = [0, 10, 10, 30, 31]
        XCTAssertEqual(TreeDrawer.Item.instanceRanges(count: 31, starts: starts, quarters: TileQuarters.all, share: 1),
                       [0..<10, 10..<30, 30..<31])
        XCTAssertEqual(TreeDrawer.Item.instanceRanges(count: 31, starts: starts, quarters: 0b1100, share: 0.5),
                       [10..<20, 30..<31])
        XCTAssertEqual(TreeDrawer.Item.instanceRanges(count: 31, starts: [], quarters: TileQuarters.all, share: 0.5), [0..<16])
        XCTAssertEqual(TreeDrawer.Item.instanceRanges(count: 31, starts: [], quarters: 0b0001, share: 1), [])
    }

    /// The working copy of a quartered tile with hidden buildings keeps its
    /// quarters as runs of their own, each starting at an even index.
    func testTheWorkingCopyKeepsTheQuarters() {
        // Quarters of 6, 0, 12 and 6 indices, a building of 3 hidden in
        // the first and one of 6 in the third.
        let layout = HiddenBuildingIndexBuffers.workingLayout(runs: [0..<3, 6..<12, 18..<24],
                                                              quarterStarts: [0, 6, 6, 18, 24])
        XCTAssertEqual(layout.segments, [[0..<3], [], [6..<12], [18..<24]])
        XCTAssertEqual(layout.paddedBefore, [false, true, false, false])
        XCTAssertEqual(layout.quarterStarts, [0, 6, 6, 12, 18])
        XCTAssertEqual(layout.indexCount, 18)
        XCTAssertTrue(layout.quarterStarts.allSatisfy { $0 % 2 == 0 })

        var destination = [UInt16](repeating: 9, count: layout.indexCount)
        let source: [UInt16] = Array(0..<24)
        source.withUnsafeBytes { from in
            destination.withUnsafeMutableBytes { to in
                HiddenBuildingIndexBuffers.copy(layout: layout,
                                                indexByteCount: 2,
                                                from: from.baseAddress!,
                                                to: to.baseAddress!)
            }
        }
        XCTAssertEqual(destination, [0, 1, 2, 0, 0, 0, 6, 7, 8, 9, 10, 11, 18, 19, 20, 21, 22, 23])
    }

    /// The quarter starts of a cached tile are untrusted: none, or five
    /// that start at zero, never go down and end at the count.
    func testCachedQuarterStartsAreChecked() {
        XCTAssertEqual(MetalTileFactory.quarterStarts([], count: 12), [])
        XCTAssertEqual(MetalTileFactory.quarterStarts([0, 4, 4, 8, 12], count: 12), [0, 4, 4, 8, 12])
        XCTAssertNil(MetalTileFactory.quarterStarts([0, 4, 8, 12], count: 12), "Four")
        XCTAssertNil(MetalTileFactory.quarterStarts([0, 8, 4, 10, 12], count: 12), "Down")
        XCTAssertNil(MetalTileFactory.quarterStarts([0, 4, 4, 8, 14], count: 12), "Past the count")
        XCTAssertNil(MetalTileFactory.quarterStarts([2, 4, 4, 8, 12], count: 12), "Not from zero")
    }
}
