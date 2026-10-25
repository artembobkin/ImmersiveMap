// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Accelerate

/// Welds a terrain tile's edges to its neighbours' of the same zoom.
///
/// A terrain tile's pixel is a cell, its height the cell's middle's
/// (Terrarium, Mapbox Terrain-RGB): no pixel lies on the tile's edge,
/// whose height is between the tile's last pixel and its neighbour's
/// first. The ground over a tile reads its edge as the last pixel (the
/// sampler clamps at it), the ground over the neighbour as the first one,
/// and the two meet with a step as tall as the slope over one pixel: a
/// crack tens of metres high on a mountain at the coarse zooms. Welded,
/// both edges hold the mean of the two pixels, the height on the edge
/// itself, and the ground closes. Only the last half pixel at the edge
/// moves, by half the step.
///
/// Each edge but its two end texels is welded with the neighbour across
/// it. Each corner texel, where four tiles meet, takes the mean of the
/// corners of the tiles that are in, so every one of them holds the same.
/// A tile with no neighbour in keeps its edge as decoded, and is welded
/// when the neighbour arrives. The means are of the decoded edges
/// (`GroundReliefTile.originalEdges`), so the weld is the same in any
/// order of arrival, and a neighbour that leaves and comes back welds to
/// the same values. Tiles of another size are left apart.
enum GroundReliefEdgeWeld {
    /// One write into a tile's texels: a rectangle of `width` by `height`
    /// from the column `x` and the row `y`, row by row.
    struct Write {
        let terrain: GroundReliefTile
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let values: [UInt16]
    }

    /// The writes that weld `terrain`, just arrived at `tile`, to the
    /// neighbours `neighbour` finds in (the tile itself among them): its
    /// four edges and its four corners, and the neighbours' sides of them.
    static func writes(for tile: Tile,
                       terrain: GroundReliefTile,
                       neighbour: (Tile) -> GroundReliefTile?) -> [Write] {
        let size = terrain.size
        guard size >= 2 else { return [] }
        let count = 1 << tile.z
        func find(_ x: Int, _ y: Int) -> (tile: Tile, terrain: GroundReliefTile)? {
            guard y >= 0, y < count else { return nil }
            let wrapped = ((x % count) + count) % count
            let address = Tile(x: wrapped, y: y, z: tile.z)
            let found = address == tile ? terrain : neighbour(address)
            guard let found, found.size == size else { return nil }
            return (address, found)
        }
        var writes: [Write] = []
        let inner = size - 2

        // The edges: the tile's side and the neighbour's, without the end
        // texels, which are the corners'.
        if inner > 0 {
            if let east = find(tile.x + 1, tile.y), east.terrain !== terrain {
                let mean = means(terrain.originalEdges.east, east.terrain.originalEdges.west)
                writes.append(Write(terrain: terrain, x: size - 1, y: 1, width: 1, height: inner, values: mean))
                writes.append(Write(terrain: east.terrain, x: 0, y: 1, width: 1, height: inner, values: mean))
            }
            if let west = find(tile.x - 1, tile.y), west.terrain !== terrain {
                let mean = means(terrain.originalEdges.west, west.terrain.originalEdges.east)
                writes.append(Write(terrain: terrain, x: 0, y: 1, width: 1, height: inner, values: mean))
                writes.append(Write(terrain: west.terrain, x: size - 1, y: 1, width: 1, height: inner, values: mean))
            }
            if let north = find(tile.x, tile.y - 1) {
                let mean = means(terrain.originalEdges.north, north.terrain.originalEdges.south)
                writes.append(Write(terrain: terrain, x: 1, y: 0, width: inner, height: 1, values: mean))
                writes.append(Write(terrain: north.terrain, x: 1, y: size - 1, width: inner, height: 1, values: mean))
            }
            if let south = find(tile.x, tile.y + 1) {
                let mean = means(terrain.originalEdges.south, south.terrain.originalEdges.north)
                writes.append(Write(terrain: terrain, x: 1, y: size - 1, width: inner, height: 1, values: mean))
                writes.append(Write(terrain: south.terrain, x: 1, y: 0, width: inner, height: 1, values: mean))
            }
        }

        // The corners, by the point of the tile grid each lies on: the
        // four tiles around the point, each by its corner there.
        let last = size - 1
        for (pointX, pointY) in [(tile.x, tile.y), (tile.x + 1, tile.y), (tile.x, tile.y + 1), (tile.x + 1, tile.y + 1)] {
            var corners: [(terrain: GroundReliefTile, x: Int, y: Int)] = []
            // North-west of the point, its south-east corner; north-east,
            // its south-west; south-west, its north-east; south-east, its
            // north-west.
            for (dx, dy, cornerX, cornerY) in [(-1, -1, last, last), (0, -1, 0, last), (-1, 0, last, 0), (0, 0, 0, 0)] {
                // At the lowest zooms a tile is its own neighbour across
                // the antimeridian: its corner counts once.
                guard let found = find(pointX + dx, pointY + dy),
                      corners.contains(where: { $0.terrain === found.terrain }) == false else { continue }
                corners.append((found.terrain, cornerX, cornerY))
            }
            guard corners.count > 1 else { continue }
            let total = corners.reduce(Float(0)) { sum, corner in
                sum + GroundReliefTile.float(halfBits: corner.terrain.originalCorner(x: corner.x, y: corner.y))
            }
            let value = halves([total / Float(corners.count)])
            for corner in corners {
                writes.append(Write(terrain: corner.terrain, x: corner.x, y: corner.y, width: 1, height: 1, values: value))
            }
        }
        return writes
    }

    /// The means of two edges texel by texel, without their end texels,
    /// as half floats.
    private static func means(_ first: [UInt16], _ second: [UInt16]) -> [UInt16] {
        let floats = (1 ..< first.count - 1).map { index in
            (GroundReliefTile.float(halfBits: first[index]) + GroundReliefTile.float(halfBits: second[index])) / 2
        }
        return halves(floats)
    }

    /// Floats as half floats: `Float16` is not on every platform the
    /// package builds for.
    static func halves(_ floats: [Float]) -> [UInt16] {
        var source = floats
        var result = [UInt16](repeating: 0, count: floats.count)
        guard floats.isEmpty == false else { return result }
        source.withUnsafeMutableBytes { sourceBytes in
            result.withUnsafeMutableBytes { resultBytes in
                var sourceBuffer = vImage_Buffer(data: sourceBytes.baseAddress, height: 1,
                                                 width: vImagePixelCount(floats.count), rowBytes: floats.count * 4)
                var resultBuffer = vImage_Buffer(data: resultBytes.baseAddress, height: 1,
                                                 width: vImagePixelCount(floats.count), rowBytes: floats.count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&sourceBuffer, &resultBuffer, vImage_Flags(kvImageNoFlags))
            }
        }
        return result
    }
}

extension GroundReliefTile {
    /// The decoded texel at a corner, `x` and `y` each 0 or `size - 1`.
    func originalCorner(x: Int, y: Int) -> UInt16 {
        let row = y == 0 ? originalEdges.north : originalEdges.south
        return row[x]
    }
}
