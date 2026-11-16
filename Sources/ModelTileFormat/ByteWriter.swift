// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Appends little-endian values to a growing byte buffer: how a tile's
/// header, tables and blocks are written. Public, so a baker writes the
/// rest of its archive (the PMTiles header around the tiles) with the same
/// writer and keeps none of its own.
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public var count: Int {
        data.count
    }

    public mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    public mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    public mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    public mutating func append(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func append(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    /// Zero bytes up to the next multiple of `alignment`.
    public mutating func pad(toMultipleOf alignment: Int) {
        let remainder = data.count % alignment
        if remainder != 0 {
            data.append(Data(count: alignment - remainder))
        }
    }
}
