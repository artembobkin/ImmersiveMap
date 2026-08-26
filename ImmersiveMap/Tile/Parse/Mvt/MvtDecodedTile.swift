// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A `repeated uint32` protobuf field, kept as a byte range into the tile
/// payload when it arrived as one contiguous packed run (the overwhelmingly
/// common encoding for MVT `tags` and `geometry`). The `values` case covers
/// unpacked elements and packed runs split across several chunks, which the
/// wire format permits.
enum MvtPackedField {
    case empty
    /// Byte offsets into the tile payload, counted from the start of the
    /// buffer `Data.withUnsafeBytes` exposes.
    case range(Range<Int>)
    case values([UInt32])

    /// Decodes the field into an array; tests and rare fallbacks only, the
    /// hot paths read the range in place.
    func materializedValues(data: Data) -> [UInt32] {
        switch self {
        case .empty:
            return []
        case .values(let values):
            return values
        case .range(let range):
            return data.withUnsafeBytes { bytes in
                guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return [] }
                var reader = MvtVarintUInt32Reader(bytes: bytes, range: range)
                var values: [UInt32] = []
                values.reserveCapacity(range.count)
                while let value = reader.next() {
                    values.append(value)
                }
                return values
            }
        }
    }
}

struct MvtDecodedFeature {
    var id: UInt64 = 0
    var hasID: Bool = false
    var type: MvtGeometryType = .unknown
    var tags: MvtPackedField = .empty
    var geometry: MvtPackedField = .empty
}

struct MvtDecodedLayer {
    var name: String = ""
    var extent: UInt32 = 4096
    var keys: [String] = []
    var values: [MvtValue] = []
    var features: [MvtDecodedFeature] = []
}

/// The result of the hand-written wire decode: layers plus the payload the
/// packed-field ranges point into.
struct MvtDecodedTile {
    let layers: [MvtDecodedLayer]
    let sourceData: Data
}

/// Reads protobuf varints as uint32 values straight from raw bytes.
struct MvtVarintUInt32Reader: MvtUInt32Reading {
    private let bytes: UnsafeRawBufferPointer
    private var offset: Int
    private let end: Int

    init(bytes: UnsafeRawBufferPointer, range: Range<Int>) {
        self.bytes = bytes
        self.offset = range.lowerBound
        self.end = range.upperBound
    }

    /// Upper bound on how many values remain (each varint is at least one
    /// byte); used only to cap capacity reservations.
    var remainingCountUpperBound: Int { end - offset }

    @inline(__always)
    mutating func next() -> UInt32? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < end {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) &<< shift
            if byte & 0x80 == 0 {
                // Repeated uint32 fields truncate oversized varints to their
                // low 32 bits, as the protobuf encoding rules specify.
                return UInt32(truncatingIfNeeded: result)
            }
            shift += 7
            if shift >= 64 {
                return nil
            }
        }
        return nil
    }
}

/// Reads uint32 values from an already-materialized array.
struct MvtArrayUInt32Reader: MvtUInt32Reading {
    private let values: [UInt32]
    private var index = 0

    init(values: [UInt32]) {
        self.values = values
    }

    var remainingCountUpperBound: Int { values.count - index }

    @inline(__always)
    mutating func next() -> UInt32? {
        guard index < values.count else { return nil }
        let value = values[index]
        index += 1
        return value
    }
}

/// Sequential uint32 source the geometry and tag state machines run over, so
/// the packed byte range and the materialized fallback share one
/// implementation. Both conformers are structs; the generic specializer
/// inlines `next()` into the loops.
protocol MvtUInt32Reading {
    mutating func next() -> UInt32?
    var remainingCountUpperBound: Int { get }
}
