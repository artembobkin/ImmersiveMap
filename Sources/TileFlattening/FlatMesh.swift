// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// An 8-bit sRGB color with straight (non-premultiplied) alpha.
public struct FlatColor: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Components in 0...1.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(r: byte(red), g: byte(green), b: byte(blue), a: byte(alpha))
    }

    /// `r` in the lowest byte, `a` in the highest: the byte order of `rgba8Unorm` on little-endian.
    public var packed: UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24
    }

    public init(packed: UInt32) {
        self.init(
            r: UInt8(truncatingIfNeeded: packed),
            g: UInt8(truncatingIfNeeded: packed >> 8),
            b: UInt8(truncatingIfNeeded: packed >> 16),
            a: UInt8(truncatingIfNeeded: packed >> 24)
        )
    }
}

/// A mesh vertex: position in tile units (x right, y down) and a baked color (`FlatColor.packed`).
/// The layout is 12 bytes and can be handed to the GPU as is.
public struct FlatVertex: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var color: UInt32

    public init(x: Float, y: Float, color: UInt32) {
        self.x = x
        self.y = y
        self.color = color
    }
}

/// A flattened tile: triangles that do not overlap, each with one flat color.
///
/// Vertices are shared only inside one color region, so the three vertices of a triangle always
/// carry the same color. Every triangle has a positive signed area in tile coordinates.
public struct FlatMesh: Sendable {
    public var vertices: [FlatVertex]
    public var indices: [UInt32]

    public init(vertices: [FlatVertex] = [], indices: [UInt32] = []) {
        self.vertices = vertices
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }
}
