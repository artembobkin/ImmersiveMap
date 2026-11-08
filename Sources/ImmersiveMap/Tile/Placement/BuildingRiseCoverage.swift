// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// How far the buildings drawn over a point of the map have risen this
/// frame, by the tile and the quarters they draw from
/// (`BuildingCoveragePlanner`, `PlaceTile.quarters`): what a label on a
/// roof rises by. A label is asked for by its own tile and its place in
/// it, and the buildings over that place may come from another zoom: a
/// zoom 14 label over a quarter its zoom 15 child draws stands on the
/// child's roofs, a zoom 15 label under a quarter its parent draws on the
/// parent's, and a label over a quarter nothing draws stays on the
/// ground. The coverage draws each point of the ground from one tile at
/// most, so the first drawn tile found over the point is the one.
struct BuildingRiseCoverage {
    private struct Entry {
        var rise: Float
        var quarters: UInt8
    }

    private var entries: [Tile: Entry] = [:]
    private var minimumZoom = Int.max
    private var maximumZoom = Int.min

    static let none = BuildingRiseCoverage()

    var isEmpty: Bool { entries.isEmpty }

    /// Adds the buildings of `tile` drawn in `quarters`, risen by `rise`.
    /// A tile drawn in two world copies keeps the higher rise and the
    /// quarters of both.
    mutating func add(tile: Tile, quarters: UInt8, rise: Float) {
        var entry = entries[tile] ?? Entry(rise: 0, quarters: 0)
        entry.rise = max(entry.rise, rise)
        entry.quarters |= quarters
        entries[tile] = entry
        minimumZoom = min(minimumZoom, tile.z)
        maximumZoom = max(maximumZoom, tile.z)
    }

    /// The rise of the buildings drawn at `uv` of `tile` (u east, v from
    /// the north edge, both 0 to 1), 0 where none draw.
    func rise(tile: Tile, uv: SIMD2<Float>) -> Float {
        guard entries.isEmpty == false else { return 0 }
        let u = min(max(uv.x, 0), 1)
        let v = min(max(uv.y, 0), 1)
        // The tile itself and the finer ones over the point.
        if tile.z <= maximumZoom {
            for depth in 0...(maximumZoom - tile.z) {
                let scale = 1 << depth
                let fine = Tile(x: tile.x * scale + min(Int(u * Float(scale)), scale - 1),
                                y: tile.y * scale + min(Int(v * Float(scale)), scale - 1),
                                z: tile.z + depth)
                if let rise = drawnRise(of: fine, u: u * Float(scale) - Float(fine.x - tile.x * scale),
                                        v: v * Float(scale) - Float(fine.y - tile.y * scale)) {
                    return rise
                }
            }
        }
        // The coarser ones under it.
        var zoom = min(tile.z - 1, maximumZoom)
        while zoom >= minimumZoom {
            let shift = tile.z - zoom
            let scale = Float(1 << shift)
            let coarse = Tile(x: tile.x >> shift, y: tile.y >> shift, z: zoom)
            let coarseU = (Float(tile.x - (coarse.x << shift)) + u) / scale
            let coarseV = (Float(tile.y - (coarse.y << shift)) + v) / scale
            if let rise = drawnRise(of: coarse, u: coarseU, v: coarseV) {
                return rise
            }
            zoom -= 1
        }
        return 0
    }

    /// The rise of `tile` when it draws the quarter at (`u`, `v`) of it.
    private func drawnRise(of tile: Tile, u: Float, v: Float) -> Float? {
        guard let entry = entries[tile] else { return nil }
        let quarter = (v >= 0.5 ? 2 : 0) + (u >= 0.5 ? 1 : 0)
        return entry.quarters & (1 << quarter) != 0 ? entry.rise : nil
    }
}
