// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The occlusion of the sky by the terrain, computed from a terrain tile's
/// own heights (`ImmersiveMapTerrainOcclusion`, `GroundReliefStore`): for
/// a grid of `resolution` points a side over the tile, the mean over
/// `directions` directions of the sine of the horizon's elevation, the
/// steepest line of sight to the terrain out to the radius. Level ground
/// and a summit see the whole sky and get 0, the floor of a gorge sees
/// little of it and gets close to 1. Kept as bytes, 255 for 1, which the
/// store puts in an `r8Unorm` texture the fills' fragment stages sample
/// (`groundReliefOcclude` in GroundRelief.h).
///
/// The terrain is read within the tile alone: a ridge just across the
/// tile's edge is not seen from a point near the edge, which lightens a
/// band of the radius' width along the edges a little. The welded edges
/// change the heights by at most half a texel's step, which is not
/// computed again.
enum GroundReliefOcclusion {
    /// What a tile's occlusion was computed with: the same key, the same
    /// bytes. A style that darkens nothing has a resolution of 0, and
    /// nothing is computed for it.
    struct Key: Equatable, Sendable {
        let radiusMetres: Float
        let directions: Int
        let resolution: Int

        init(radiusMetres: Float, directions: Int, resolution: Int) {
            self.radiusMetres = max(0, radiusMetres.isFinite ? radiusMetres : 0)
            self.directions = min(max(directions, 4), 32)
            self.resolution = resolution <= 0 ? 0 : min(max(resolution, 16), 1024)
        }

        init(style: ImmersiveMapTerrainOcclusion) {
            self.init(radiusMetres: style.radiusMeters,
                      directions: style.directions,
                      resolution: style.isEnabled ? style.resolution : 0)
        }

        /// Whether anything is computed under this key.
        var computes: Bool { resolution > 0 && radiusMetres > 0 }
    }

    /// The ground metres a texel of a terrain tile of `size` texels a
    /// side spans, at the tile's middle latitude.
    static func metresPerTexel(tile: Tile, size: Int) -> Float {
        let count = Double(1 << max(tile.z, 0))
        let middleY = (Double(tile.y) + 0.5) / count
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: middleY)
        let sideMetres = 2 * Double.pi * 6_378_137 * cos(latitude) / count
        return Float(sideMetres / Double(max(size, 1)))
    }

    /// The distances the lines of sight step out at, in texels: every
    /// texel near, then growing by a quarter each step, out to the radius.
    static func steps(radiusTexels: Float) -> [Float] {
        var steps: [Float] = []
        var distance: Float = 1
        while distance <= radiusTexels {
            steps.append(distance)
            distance = max(distance + 1, (distance * 1.25).rounded(.down))
        }
        return steps
    }

    /// The occlusion over a tile, `key.resolution` squared bytes, row 0
    /// at the north edge as the heights are. `halves` are the tile's
    /// heights as half floats, `size` a side.
    static func compute(halves: [UInt16], size: Int, metresPerTexel: Float, key: Key) -> [UInt8] {
        let resolution = key.resolution
        var result = [UInt8](repeating: 0, count: resolution * resolution)
        guard key.computes, size > 1, metresPerTexel > 0, halves.count == size * size else { return result }
        let heights = halves.map(GroundReliefTile.float(halfBits:))
        let steps = steps(radiusTexels: key.radiusMetres / metresPerTexel)
        guard steps.isEmpty == false else { return result }
        // The lines of sight as texel offsets, direction by direction, step
        // by step, with one over the ground metres of each step: the inner
        // loop adds and multiplies, nothing else.
        var offsetX: [Int] = []
        var offsetY: [Int] = []
        var inverseMetres: [Float] = []
        offsetX.reserveCapacity(key.directions * steps.count)
        offsetY.reserveCapacity(key.directions * steps.count)
        inverseMetres.reserveCapacity(key.directions * steps.count)
        for index in 0 ..< key.directions {
            let angle = 2 * Float.pi * Float(index) / Float(key.directions)
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            for distance in steps {
                offsetX.append(Int((direction.x * distance).rounded()))
                offsetY.append(Int((direction.y * distance).rounded()))
                inverseMetres.append(1 / (distance * metresPerTexel))
            }
        }
        let stepCount = steps.count
        let share = 255 / Float(key.directions)
        heights.withUnsafeBufferPointer { heights in
            offsetX.withUnsafeBufferPointer { offsetX in
                offsetY.withUnsafeBufferPointer { offsetY in
                    inverseMetres.withUnsafeBufferPointer { inverseMetres in
                        result.withUnsafeMutableBufferPointer { result in
                            for row in 0 ..< resolution {
                                let y = Int((Float(row) + 0.5) * Float(size) / Float(resolution))
                                for column in 0 ..< resolution {
                                    let x = Int((Float(column) + 0.5) * Float(size) / Float(resolution))
                                    let base = heights[y * size + x]
                                    var sum: Float = 0
                                    var index = 0
                                    for _ in 0 ..< key.directions {
                                        var steepest: Float = 0
                                        var step = 0
                                        while step < stepCount {
                                            let sampleX = x + offsetX[index + step]
                                            let sampleY = y + offsetY[index + step]
                                            if sampleX < 0 || sampleY < 0 || sampleX >= size || sampleY >= size {
                                                break
                                            }
                                            let slope = (heights[sampleY * size + sampleX] - base) * inverseMetres[index + step]
                                            if slope > steepest {
                                                steepest = slope
                                            }
                                            step += 1
                                        }
                                        sum += steepest / (1 + steepest * steepest).squareRoot()
                                        index += stepCount
                                    }
                                    result[row * resolution + column] = UInt8(min(255, max(0, (sum * share).rounded())))
                                }
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}
