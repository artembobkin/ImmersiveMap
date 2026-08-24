// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// Densities the debug tile grid offers. Six is the default: it splits a tile
/// finely enough to point at a single block of a city while the per-cell stamp
/// still reads at a normal zoom.
enum DebugTileGridDensity {
    static let options: [Int] = [2, 4, 6, 8]
    static let standard: Int = 6

    /// Nearest offered density, so a stored value can never draw a grid nobody
    /// can select back.
    static func clamp(_ density: Int) -> Int {
        guard let nearest = options.min(by: { abs($0 - density) < abs($1 - density) }) else {
            return standard
        }
        return nearest
    }
}

/// One grid line piece in tile UV space, flagged as the tile's own border or an
/// interior division so the two can be drawn at different thicknesses.
/// Rectangle in tile UV, used for the plate laid under a cell's stamp.
struct TileGridUVRect: Equatable {
    let minU: Float
    let minV: Float
    let maxU: Float
    let maxV: Float
}

struct TileGridLineSegment {
    let start: SIMD2<Float>
    let end: SIMD2<Float>
    let isBorder: Bool
}

/// Geometry and stamps of the debug tile grid: the overlay that divides the tile
/// under the camera centre into `density x density` cells and writes over each
/// cell which slice of that tile's geometry it covers.
///
/// **Coordinate convention, which is the whole point of the overlay.** The bounds
/// a cell prints are the RAW `.mvt` units, 0 to 4096, with **x growing east and
/// y growing south from the NORTH edge of the tile** - exactly what a tile
/// decoder, a grep over tile bodies or the pipeline's GeoJSON shows, so a stamp
/// can be pasted into any of them unchanged. The first cut of this overlay
/// printed y in the parser's own space instead (it flips the incoming MVT y to
/// `tileExtent - y`), and the very first debugging session went to the mirrored
/// half of the tile; the stamps exist for cross-referencing the DATA, and the
/// data speaks MVT. To reach the parser's space, take `4096 - y`.
///
/// A cell code is the same box spelled differently: the letter is the column
/// index counted from the west (A is x 0 upward), the number is the row index
/// counted from the north starting at one (1 is y 0 downward), reading like the
/// rows of a table. So `C4` at density six is exactly `x1365-2047 y2048-2730`,
/// and either half of the stamp is enough to find the geometry.
///
/// Tile UV, which the projector takes, runs the same way: `uv.y = 0` is the
/// north edge in both the flat and the globe kernel, so `cellUVRect` maps the
/// row index straight through.
enum DebugTileGridMath {
    /// Tile-local extent the stamps are expressed in, matching
    /// `TileLocalClipMath.tileExtent`.
    static let tileExtent: Int = 4096

    /// The `density + 1` lines each way, each cut into `segmentCountPerEdge`
    /// pieces so that on the globe a line follows the sphere instead of cutting
    /// through it.
    static func makeGridSegments(density: Int,
                                 segmentCountPerEdge: Int) -> [TileGridLineSegment] {
        let clampedDensity = max(1, density)
        let clampedSegments = max(1, segmentCountPerEdge)
        let lineStep = 1.0 / Float(clampedDensity)
        let pieceStep = 1.0 / Float(clampedSegments)
        var segments: [TileGridLineSegment] = []
        segments.reserveCapacity((clampedDensity + 1) * 2 * clampedSegments)

        for lineIndex in 0...clampedDensity {
            let position = min(Float(lineIndex) * lineStep, 1.0)
            let isBorder = lineIndex == 0 || lineIndex == clampedDensity
            for pieceIndex in 0..<clampedSegments {
                let from = Float(pieceIndex) * pieceStep
                let to = Float(pieceIndex + 1) * pieceStep
                segments.append(TileGridLineSegment(start: SIMD2<Float>(position, from),
                                                    end: SIMD2<Float>(position, to),
                                                    isBorder: isBorder))
                segments.append(TileGridLineSegment(start: SIMD2<Float>(from, position),
                                                    end: SIMD2<Float>(to, position),
                                                    isBorder: isBorder))
            }
        }
        return segments
    }

    /// Inclusive tile-local bounds of one cell along an axis. Densities that do
    /// not divide 4096 evenly (six does not) get the rounded partition, so cells
    /// still tile 0...4095 with no gap and no overlap.
    static func cellBounds(index: Int, density: Int) -> (lo: Int, hi: Int) {
        let clampedDensity = max(1, density)
        let clampedIndex = min(max(index, 0), clampedDensity - 1)
        let extent = Double(tileExtent)
        let lo = Int((Double(clampedIndex) * extent / Double(clampedDensity)).rounded())
        let next = Int((Double(clampedIndex + 1) * extent / Double(clampedDensity)).rounded())
        return (lo: lo, hi: next - 1)
    }

    /// Column letter from the west plus row number from the north, one-based.
    static func cellCode(column: Int, row: Int) -> String {
        "\(columnLetters(column))\(max(0, row) + 1)"
    }

    /// The four lines stamped over a cell: the tile it belongs to, the cell code,
    /// and the cell's tile-local x and y bounds. Each cell is self-sufficient on
    /// purpose, so a screenshot cropped to one cell still says where to look.
    ///
    /// A fifth `src` line appears when the slot is drawn with a substitute tile's
    /// geometry, because then the pixels under the stamp were not built from the tile
    /// the first line names: they come from `sourceTile`, mapped into the slot by
    /// `TileLocalClipMath.clipBounds(source:placeIn:)`. Without the line the stamp
    /// would point at a tile that is not on screen.
    static func cellLabelLines(tile: Tile,
                               column: Int,
                               row: Int,
                               density: Int,
                               sourceTile: Tile? = nil) -> [String] {
        let xBounds = cellBounds(index: column, density: density)
        let yBounds = cellBounds(index: row, density: density)
        var lines = [
            "\(tile.x)/\(tile.y)/\(tile.z)",
            cellCode(column: column, row: row),
            "x\(xBounds.lo)-\(xBounds.hi)",
            "y\(yBounds.lo)-\(yBounds.hi)"
        ]
        if let sourceTile, sourceTile != tile {
            lines.append("src \(sourceTile.x)/\(sourceTile.y)/\(sourceTile.z)")
        }
        return lines
    }

    /// The cell's rectangle in tile UV. The row index and `uv.y` both count
    /// from the north, so the mapping is straight: row 0 is the top band.
    static func cellUVRect(column: Int,
                           row: Int,
                           density: Int) -> (minU: Float, minV: Float, maxU: Float, maxV: Float) {
        let clampedDensity = max(1, density)
        let step = 1.0 / Float(clampedDensity)
        let clampedColumn = min(max(column, 0), clampedDensity - 1)
        let clampedRow = min(max(row, 0), clampedDensity - 1)
        return (minU: Float(clampedColumn) * step,
                minV: Float(clampedRow) * step,
                maxU: Float(clampedColumn + 1) * step,
                maxV: Float(clampedRow + 1) * step)
    }

    /// The plate laid under a cell's stamp: the union of the laid-out lines,
    /// grown by `paddingUV`. Every line is centred on its own anchor and spans
    /// twice its half size, so the union is the smallest rectangle that covers
    /// the text and nothing else. Kept tight on purpose: the plate exists to keep
    /// map labels from muddying the stamp, not to hide the tile it is drawn on.
    static func makeStampPlate(lineAnchors: [SIMD2<Float>],
                               lineHalfSizes: [SIMD2<Float>],
                               paddingUV: Float) -> TileGridUVRect? {
        guard lineAnchors.isEmpty == false,
              lineAnchors.count == lineHalfSizes.count else {
            return nil
        }

        var minCorner = SIMD2<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxCorner = SIMD2<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for index in lineAnchors.indices {
            let anchor = lineAnchors[index]
            let halfSize = lineHalfSizes[index]
            guard anchor.x.isFinite, anchor.y.isFinite,
                  halfSize.x.isFinite, halfSize.y.isFinite else {
                continue
            }
            minCorner = simd_min(minCorner, anchor - halfSize)
            maxCorner = simd_max(maxCorner, anchor + halfSize)
        }
        guard minCorner.x <= maxCorner.x, minCorner.y <= maxCorner.y else {
            return nil
        }

        let padding = max(0.0, paddingUV)
        return TileGridUVRect(minU: minCorner.x - padding,
                              minV: minCorner.y - padding,
                              maxU: maxCorner.x + padding,
                              maxV: maxCorner.y + padding)
    }

    private static func columnLetters(_ column: Int) -> String {
        var remaining = max(0, column)
        var letters = ""
        repeat {
            let letterIndex = remaining % 26
            let scalarValue = UnicodeScalar(UInt8(65 + letterIndex))
            letters = String(Character(scalarValue)) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }
}
