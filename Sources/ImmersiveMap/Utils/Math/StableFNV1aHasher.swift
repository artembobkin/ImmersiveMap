// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

struct StableFNV1aHasher {
    private static let seed: UInt64 = 1469598103934665603
    private static let prime: UInt64 = 1099511628211

    private var hash: UInt64 = seed

    mutating func combine(_ value: UInt64) {
        hash ^= value
        hash &*= Self.prime
    }

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            combine(UInt64(byte))
        }
    }

    func finalize() -> UInt64 {
        hash
    }
}
