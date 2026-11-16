// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Appends little-endian values to a growing byte buffer: how a tile's
/// header, tables and blocks are written.
struct ByteWriter {
    private(set) var data = Data()

    var count: Int {
        data.count
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func append(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    /// Zero bytes up to the next multiple of `alignment`.
    mutating func pad(toMultipleOf alignment: Int) {
        let remainder = data.count % alignment
        if remainder != 0 {
            data.append(Data(count: alignment - remainder))
        }
    }
}
