// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

struct VectorTileLabelStableHasher {
    private static let seed: UInt64 = 1469598103934665603
    private static let prime: UInt64 = 1099511628211

    private var hash: UInt64 = seed

    mutating func combine(_ value: UInt64) {
        hash ^= value
        hash &*= Self.prime
    }

    mutating func combine(_ value: Int) {
        combine(UInt64(bitPattern: Int64(value)))
    }

    mutating func combine(_ value: UInt32) {
        combine(UInt64(value))
    }

    mutating func combine(_ value: Int16) {
        combine(UInt64(UInt16(bitPattern: value)))
    }

    mutating func combine(_ value: String) {
        combine(UInt64(value.utf8.count))
        for byte in value.utf8 {
            combine(UInt64(byte))
        }
    }

    func finalize() -> UInt64 {
        hash
    }
}
