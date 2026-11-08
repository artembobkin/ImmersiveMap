// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The four quarters of a tile: the squares of its four children, one zoom
/// finer. A tile coarser than the tileset's deepest zoom keeps its
/// buildings and its trees quarter by quarter (`ParsePolygon.ClipSquare`,
/// `TileBuffers.Extruded.quarterIndexStarts`, `TileBuffers.treeQuarterStarts`),
/// each piece cut at the quarter's edges as a child cuts its own at its
/// tile's, so the frame draws a quarter where its child is not there to
/// draw it (`BuildingCoveragePlanner`). A quarter is numbered by where it
/// lies in tile space, x east and y south: 0 the north-west, 1 the
/// north-east, 2 the south-west, 3 the south-east, the order a quarter's
/// pieces are laid out in.
enum TileQuarters {
    static let count = 4
    /// Every quarter, the mask a whole tile draws with.
    static let all: UInt8 = 0b1111

    /// The quarter a point in tile space (y south, raw MVT) lies in. A
    /// point on a quarter's edge goes east and south.
    static func quarter(ofTilePoint point: SIMD2<Float>) -> Int {
        let half = TileCoordinateSpace.tileExtent / 2
        return (point.y >= half ? 2 : 0) + (point.x >= half ? 1 : 0)
    }

    /// The quarter a point in render space (y north) lies in.
    static func quarter(ofRenderPoint point: SIMD2<Float>) -> Int {
        quarter(ofTilePoint: TileCoordinateSpace.renderPoint(point))
    }

    /// The square of `quarter` in tile space.
    static func square(of quarter: Int) -> ParsePolygon.ClipSquare {
        let half = TileCoordinateSpace.tileExtent / 2
        let corner = SIMD2<Float>(Float(quarter & 1), Float(quarter >> 1)) * half
        return ParsePolygon.ClipSquare(minimum: corner, maximum: corner + SIMD2<Float>(repeating: half))
    }

    /// The child of `tile` whose square is `quarter`.
    static func child(of tile: Tile, quarter: Int) -> Tile {
        Tile(x: tile.x * 2 + (quarter & 1), y: tile.y * 2 + (quarter >> 1), z: tile.z + 1)
    }

    /// The runs of `starts` (a tile's five quarter starts, the last one its
    /// count) that `mask` draws, consecutive quarters joined into one run.
    /// Empty `starts` is a tile kept whole: `whole` is drawn when the mask
    /// holds every quarter, and nothing otherwise.
    static func runs(starts: [Int], whole: Range<Int>, mask: UInt8) -> [Range<Int>] {
        guard starts.count == count + 1 else {
            return mask == all ? [whole] : []
        }
        var runs: [Range<Int>] = []
        for quarter in 0..<count where mask & (1 << quarter) != 0 {
            let run = starts[quarter]..<starts[quarter + 1]
            guard run.isEmpty == false else { continue }
            if let last = runs.last, last.upperBound == run.lowerBound {
                runs[runs.count - 1] = last.lowerBound..<run.upperBound
            } else {
                runs.append(run)
            }
        }
        return runs
    }
}
