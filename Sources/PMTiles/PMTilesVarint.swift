// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A cursor over a directory's bytes reading unsigned LEB128 integers, the
/// only encoding the directory uses. Bounds are checked on every byte so a
/// truncated directory throws instead of reading past the buffer.
package struct PMTilesVarintReader {
    private let bytes: [UInt8]
    package private(set) var offset: Int

    package init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    package var isAtEnd: Bool {
        offset >= bytes.count
    }

    package mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else {
                throw PMTilesFormatError.truncated
            }
            let byte = bytes[offset]
            offset += 1
            if shift >= 64 {
                throw PMTilesFormatError.malformedDirectory("varint longer than 64 bits")
            }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }
    }
}
