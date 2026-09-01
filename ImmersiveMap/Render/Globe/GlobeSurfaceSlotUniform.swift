// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The slot one placeholder fill of the globe surface covers, precomputed so
/// the vertex stage does no per-vertex pow(2, z) or Mercator row bounds;
/// mirrors the `Tile` struct the globe vertex shader reads at buffer 3
/// (Globe.metal).
struct GlobeSurfaceSlotUniform {
    /// World x of the slot's west edge, in turns.
    var uvOriginX: Float
    /// Slot-local uv to world uv: 1 / 2^z.
    var uvScale: Float
    /// The linear-latitude v of the slot's north edge and the v span to its
    /// south edge (v = 1 - (lat + pi/2) / pi), matching the grid's uv axis.
    var vNorth: Float
    var vSize: Float
    /// The normalized world x the flat morph target unwraps around: the
    /// slot's centre.
    var referenceWorldX: Float

    init(_ tile: Tile) {
        let zPow = Double(1 << tile.z)
        self.uvOriginX = Float(Double(tile.x) / zPow)
        self.uvScale = Float(1.0 / zPow)
        let latNorth = atan(sinh(.pi * (1.0 - 2.0 * Double(tile.y) / zPow)))
        let latSouth = atan(sinh(.pi * (1.0 - 2.0 * Double(tile.y + 1) / zPow)))
        let vNorthValue = 1.0 - (latNorth + .pi / 2) / .pi
        let vSouthValue = 1.0 - (latSouth + .pi / 2) / .pi
        self.vNorth = Float(vNorthValue)
        self.vSize = Float(abs(vSouthValue - vNorthValue))
        self.referenceWorldX = Float((Double(tile.x) + 0.5) / zPow)
    }
}
