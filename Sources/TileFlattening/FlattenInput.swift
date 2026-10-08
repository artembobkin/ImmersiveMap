// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The geometry to flatten: closed rings, each filled with a paint.
///
/// Paints are stacked in the order they are added: a paint added later covers the earlier ones.
/// All rings of one paint are filled together with the nonzero winding rule, so overlapping rings
/// of the same paint merge, and a ring with the opposite orientation cuts a hole.
public struct FlattenInput: Sendable {
    struct Ring {
        var start: Int32
        var count: Int32
        var paint: UInt16
    }

    public private(set) var paints: [FlatColor] = []
    /// Interleaved x, y.
    var coords: [Double] = []
    var rings: [Ring] = []
    private var openRingStart = -1
    private var openRingPaint: UInt16 = 0
    /// Scratch for the stroker.
    var strokePoints: [SIMD2<Double>] = []
    var strokeRight: [SIMD2<Double>] = []

    public init() {}

    public var ringCount: Int { rings.count }
    public var pointCount: Int { coords.count / 2 }

    public mutating func reserveCapacity(points: Int, rings ringCapacity: Int) {
        coords.reserveCapacity(points * 2)
        rings.reserveCapacity(ringCapacity)
    }

    /// Adds a paint on top of the existing ones and returns its index.
    @discardableResult
    public mutating func addPaint(_ color: FlatColor) -> Int {
        precondition(paints.count < Int(UInt16.max), "too many paints")
        paints.append(color)
        return paints.count - 1
    }

    // MARK: Rings

    /// Starts a ring. Add its points with `addPoint` and finish it with `endRing`.
    /// The ring is closed implicitly: do not repeat the first point.
    @inline(__always)
    public mutating func beginRing(paint: Int) {
        openRingStart = coords.count / 2
        openRingPaint = UInt16(paint)
    }

    @inline(__always)
    public mutating func addPoint(x: Double, y: Double) {
        coords.append(x)
        coords.append(y)
    }

    @inline(__always)
    public mutating func endRing() {
        let count = coords.count / 2 - openRingStart
        if count >= 3 {
            rings.append(Ring(start: Int32(openRingStart), count: Int32(count), paint: openRingPaint))
        } else {
            coords.removeLast(count * 2)
        }
        openRingStart = -1
    }

    public mutating func addRing(_ points: [SIMD2<Double>], paint: Int) {
        beginRing(paint: paint)
        for p in points { addPoint(x: p.x, y: p.y) }
        endRing()
    }

    /// Adds a polygon: an exterior ring and its holes. Holes must have the opposite orientation.
    public mutating func addPolygon(_ polygonRings: [[SIMD2<Double>]], paint: Int) {
        for ring in polygonRings { addRing(ring, paint: paint) }
    }

    public mutating func addRect(minX: Double, minY: Double, maxX: Double, maxY: Double, paint: Int) {
        beginRing(paint: paint)
        addPoint(x: minX, y: minY)
        addPoint(x: maxX, y: minY)
        addPoint(x: maxX, y: maxY)
        addPoint(x: minX, y: maxY)
        endRing()
    }
}
