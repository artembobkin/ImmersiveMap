// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// A vertex as a model tile holds it, `ModelTileContents.vertexStride`
/// bytes: what a baker writes into a tile's vertex block. It is made of a
/// vertex's surface, the normal, the texture layer and the texture
/// coordinate, and its place is set once the tile's bounding box is known
/// (`place`), since a position is kept as a share of that box.
///
/// Two vertices that are the same record are one vertex of the tile: a
/// baker writes each once and names it again by its index.
public struct ModelTileVertex: Hashable, Sendable {
    /// The position across the tile's bounding box, 0...65535 on each axis.
    public var x: UInt16 = 0
    public var y: UInt16 = 0
    public var z: UInt16 = 0
    /// The texture coordinate, unsigned normalized, V down.
    public var u: UInt16
    public var v: UInt16
    /// The normal, signed normalized, in tile space.
    public var normal: SIMD3<Int8>
    /// The layer of the tile's texture array.
    public var layer: UInt8

    /// A vertex of a surface, its place not yet set. `normal` is in tile
    /// space, `coordinate` inside the unit square.
    public init(normal: SIMD3<Float>, layer: UInt8, coordinate: SIMD2<Float>) {
        self.normal = SIMD3<Int8>(Self.signed(normal.x), Self.signed(normal.y), Self.signed(normal.z))
        self.layer = layer
        self.u = Self.unsigned(coordinate.x)
        self.v = Self.unsigned(coordinate.y)
    }

    /// Sets the position, given in tile space, as a place in the tile's
    /// bounding box: on each axis 0 at the box's minimum and 65535 at its
    /// maximum, the nearest step. A box with no size on an axis has every
    /// place there at 0.
    public mutating func place(_ position: SIMD3<Float>, minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        func share(_ axis: Int) -> UInt16 {
            let size = Double(maximum[axis]) - Double(minimum[axis])
            guard size > 0 else { return 0 }
            let share = (Double(position[axis]) - Double(minimum[axis])) / size
            return UInt16((max(0, min(1, share)) * 65_535).rounded())
        }
        x = share(0)
        y = share(1)
        z = share(2)
    }

    /// The vertex's bytes, appended to a vertex block.
    public func append(to block: inout Data) {
        // The fields in the tile's order, each little-endian, with the
        // reserved two bytes that make the stride a multiple of four. A
        // tuple of these lies as the tile's vertex does, with no padding.
        var record = (x.littleEndian, y.littleEndian, z.littleEndian, u.littleEndian, v.littleEndian,
                      normal.x, normal.y, normal.z, layer, UInt16(0))
        precondition(MemoryLayout.size(ofValue: record) == ModelTileContents.vertexStride)
        withUnsafeBytes(of: &record) { block.append(contentsOf: $0) }
    }

    static func signed(_ component: Float) -> Int8 {
        Int8(max(-127, min(127, (component * 127).rounded())))
    }

    static func unsigned(_ component: Float) -> UInt16 {
        UInt16((max(0, min(1, component)) * 65_535).rounded())
    }
}
