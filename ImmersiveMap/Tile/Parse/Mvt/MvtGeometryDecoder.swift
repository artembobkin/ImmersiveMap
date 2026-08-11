// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct Point {
    let x: Int32
    let y: Int32
}

struct Polygon {
    let exteriorRing: [Point]
    let interiorRings: [[Point]]
}

typealias MultiPolygon = [Polygon]
typealias LineString = [Point]
typealias MultiLineString = [LineString]
typealias MultiPoint = [Point]

/// Decodes MVT geometry command streams (MoveTo/LineTo/ClosePath with zigzag
/// deltas) straight from the packed bytes of the tile payload, without the
/// intermediate `[UInt32]` array the generated protobuf model used to carry.
/// A malformed command stream yields an empty result, matching the previous
/// decoders: the feature drops, the tile survives.
enum MvtGeometryDecoder {
    static func decodePolygons(_ field: MvtPackedField, in data: Data) -> MultiPolygon {
        data.withUnsafeBytes { bytes in
            decodePolygons(field, in: bytes)
        }
    }

    static func decodePolygons(_ field: MvtPackedField, in bytes: UnsafeRawBufferPointer) -> MultiPolygon {
        switch field {
        case .empty:
            return []
        case .range(let range):
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return [] }
            var reader = MvtVarintUInt32Reader(bytes: bytes, range: range)
            return decodePolygons(reader: &reader)
        case .values(let values):
            var reader = MvtArrayUInt32Reader(values: values)
            return decodePolygons(reader: &reader)
        }
    }

    static func decodeLines(_ field: MvtPackedField, in data: Data) -> MultiLineString {
        data.withUnsafeBytes { bytes in
            decodeLines(field, in: bytes)
        }
    }

    static func decodeLines(_ field: MvtPackedField, in bytes: UnsafeRawBufferPointer) -> MultiLineString {
        switch field {
        case .empty:
            return []
        case .range(let range):
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return [] }
            var reader = MvtVarintUInt32Reader(bytes: bytes, range: range)
            return decodeLines(reader: &reader)
        case .values(let values):
            var reader = MvtArrayUInt32Reader(values: values)
            return decodeLines(reader: &reader)
        }
    }

    static func decodePoints(_ field: MvtPackedField, in data: Data) -> MultiPoint {
        data.withUnsafeBytes { bytes in
            decodePoints(field, in: bytes)
        }
    }

    static func decodePoints(_ field: MvtPackedField, in bytes: UnsafeRawBufferPointer) -> MultiPoint {
        switch field {
        case .empty:
            return []
        case .range(let range):
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return [] }
            var reader = MvtVarintUInt32Reader(bytes: bytes, range: range)
            return decodePoints(reader: &reader)
        case .values(let values):
            var reader = MvtArrayUInt32Reader(values: values)
            return decodePoints(reader: &reader)
        }
    }

    // MARK: - Command stream state machines

    private static func decodePolygons<Reader: MvtUInt32Reading>(reader: inout Reader) -> MultiPolygon {
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        var result: [Polygon] = []
        var currentExterior: [Point]? = nil
        var currentInteriors: [[Point]] = []

        // Each ring is MoveTo(count 1), LineTo(count > 0), ClosePath.
        while let moveCmd = reader.next() {
            guard moveCmd & 0x7 == 1, moveCmd >> 3 == 1 else { return [] }

            guard let dxU1 = reader.next(), let dyU1 = reader.next() else { return [] }
            cursorX &+= decodeZigZag32(dxU1)
            cursorY &+= decodeZigZag32(dyU1)

            var ringPoints: [Point] = [Point(x: cursorX, y: cursorY)]

            guard let lineCmd = reader.next() else { return [] }
            let lineCount = Int(lineCmd >> 3)
            guard lineCmd & 0x7 == 2, lineCount > 0 else { return [] }

            // The command integer announces the point count up front; capped
            // by what could remain in the stream (2 values per point) so a
            // corrupt count cannot force a huge allocation.
            ringPoints.reserveCapacity(1 + min(lineCount, reader.remainingCountUpperBound / 2))
            for _ in 0..<lineCount {
                guard let dxU = reader.next(), let dyU = reader.next() else { return [] }
                cursorX &+= decodeZigZag32(dxU)
                cursorY &+= decodeZigZag32(dyU)
                ringPoints.append(Point(x: cursorX, y: cursorY))
            }

            guard let closeCmd = reader.next() else { return [] }
            guard closeCmd & 0x7 == 7, closeCmd >> 3 == 1 else { return [] }

            let isExterior = computeShoelace(ringPoints) > 0
            if isExterior {
                if let previousExterior = currentExterior {
                    result.append(Polygon(exteriorRing: previousExterior, interiorRings: currentInteriors))
                    currentInteriors = []
                }
                currentExterior = ringPoints
            } else {
                guard currentExterior != nil else { return [] }
                currentInteriors.append(ringPoints)
            }
        }

        if let lastExterior = currentExterior {
            result.append(Polygon(exteriorRing: lastExterior, interiorRings: currentInteriors))
        }

        return result
    }

    private static func decodeLines<Reader: MvtUInt32Reading>(reader: inout Reader) -> MultiLineString {
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0
        var result: [LineString] = []

        // Each line is MoveTo(count 1) followed by LineTo(count > 0).
        while let moveCmd = reader.next() {
            guard moveCmd & 0x7 == 1, moveCmd >> 3 == 1 else { return [] }

            guard let dxU1 = reader.next(), let dyU1 = reader.next() else { return [] }
            cursorX &+= decodeZigZag32(dxU1)
            cursorY &+= decodeZigZag32(dyU1)

            var linePoints: [Point] = [Point(x: cursorX, y: cursorY)]

            guard let lineCmd = reader.next() else { return [] }
            let lineCount = Int(lineCmd >> 3)
            guard lineCmd & 0x7 == 2, lineCount > 0 else { return [] }

            linePoints.reserveCapacity(1 + min(lineCount, reader.remainingCountUpperBound / 2))
            for _ in 0..<lineCount {
                guard let dxU = reader.next(), let dyU = reader.next() else { return [] }
                cursorX &+= decodeZigZag32(dxU)
                cursorY &+= decodeZigZag32(dyU)
                linePoints.append(Point(x: cursorX, y: cursorY))
            }

            result.append(linePoints)
        }

        return result
    }

    private static func decodePoints<Reader: MvtUInt32Reading>(reader: inout Reader) -> MultiPoint {
        var points: [Point] = []
        var cursorX: Int32 = 0
        var cursorY: Int32 = 0

        while let cmdInteger = reader.next() {
            let cmd = cmdInteger & 0x7
            let count = Int(cmdInteger >> 3)

            if cmd == 1 || cmd == 2 {
                for _ in 0..<count {
                    // A short stream keeps the points decoded so far, exactly
                    // like the previous decoder.
                    guard let dxU = reader.next(), let dyU = reader.next() else { return points }
                    cursorX &+= decodeZigZag32(dxU)
                    cursorY &+= decodeZigZag32(dyU)
                    points.append(Point(x: cursorX, y: cursorY))
                }
            } else if cmd == 7 {
                continue
            } else {
                break
            }
        }

        return points
    }

    @inline(__always)
    private static func decodeZigZag32(_ value: UInt32) -> Int32 {
        Int32(bitPattern: value >> 1) ^ -Int32(bitPattern: value & 1)
    }

    /// Wrapping arithmetic: coordinates accumulate from wrapped Int32 cursor
    /// deltas, so a crafted tile can place ring vertices anywhere in the Int32
    /// range and the cross products can reach the Int64 boundary. Wrapping
    /// keeps such garbage rings from trapping the parse; for any sane
    /// geometry the sums are nowhere near overflow and the result is exact.
    private static func computeShoelace(_ points: [Point]) -> Int64 {
        guard points.count >= 3 else { return 0 }
        var sum: Int64 = 0
        var previous = points[points.count - 1]
        for point in points {
            sum &+= Int64(previous.x) &* Int64(point.y) &- Int64(point.x) &* Int64(previous.y)
            previous = point
        }
        return sum
    }
}
