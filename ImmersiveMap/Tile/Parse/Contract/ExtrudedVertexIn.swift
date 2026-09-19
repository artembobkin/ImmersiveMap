// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// GPU vertex of the building extrusion mesh: 12 bytes.
///
/// Positions are tile-local render-space units in 14.2 fixed point
/// (`positionScale`): a quarter-unit step, which is under 15 cm at the
/// street-zoom tiles buildings ship at, with a range of two tile squares
/// of headroom for buffered roof frames. The vertex shader multiplies by
/// the inverse scale before transforming. Normals are 8-bit signed and
/// renormalized in the shader; buildings carry no per-vertex surface id
/// (no shader ever read the one the 48-byte layout stored).
///
/// The layout is mirrored by `VertexIn` in `TileExtruded.metal` and by
/// the vertex descriptor in `ExtrudedTilePipeline`. The last two bytes
/// carry the building's footprint radius, which also keeps the stride a
/// multiple of four, which Metal requires of a vertex buffer layout.
struct ExtrudedVertexIn {
    static let positionScale: Float = 4

    let positionX: Int16
    let positionY: Int16
    let positionZ: Int16
    let normalX: Int8
    let normalY: Int8
    let normalZ: Int8
    let styleIndex: UInt8
    /// The radius of the building's footprint (the circle about its centre
    /// that holds every vertex), in the same 14.2 fixed point as the
    /// positions, the same on every vertex of the building: what the
    /// vertex stage sizes the building on screen with (`BuildingLODUniform`).
    let footprintRadius: UInt16

    /// - Parameter footprintRadius: in tile units.
    init(position: SIMD3<Float>, normal: SIMD3<Float>, styleIndex: UInt8, footprintRadius: Float = 0) {
        let scaled = position * Self.positionScale
        positionX = Self.quantizePosition(scaled.x)
        positionY = Self.quantizePosition(scaled.y)
        positionZ = Self.quantizePosition(scaled.z)
        normalX = Self.quantizeNormal(normal.x)
        normalY = Self.quantizeNormal(normal.y)
        normalZ = Self.quantizeNormal(normal.z)
        self.styleIndex = styleIndex
        self.footprintRadius = UInt16(min(max((footprintRadius * Self.positionScale).rounded(), 0), Float(UInt16.max)))
    }

    /// The footprint radius in tile units.
    var footprintRadiusUnits: Float {
        Float(footprintRadius) / Self.positionScale
    }

    private static func quantizePosition(_ scaled: Float) -> Int16 {
        // Clamped, but a position past the range is a broken emitter:
        // the range covers the tile square plus two tiles of buffer.
        assert(scaled >= Float(Int16.min) && scaled <= Float(Int16.max),
               "Extruded position is outside the 14.2 fixed-point range")
        return Int16(min(max(scaled.rounded(), Float(Int16.min)), Float(Int16.max)))
    }

    private static func quantizeNormal(_ component: Float) -> Int8 {
        Int8(min(max((component * 127).rounded(), -127), 127))
    }
}
