// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Deterministic pseudo-random source for the fixture tiles and the fuzzed
/// decoder inputs. A copy of the engine test suite's `SplitMix64Generator`
/// under its own name: the test support target depends on nothing but the
/// `Mvt` module, and the device test project compiles these sources into the
/// same bundle as the engine tests, where a second type of the same name
/// would be a redeclaration.
package struct MvtSplitMix64Generator {
    private var state: UInt64

    package init(seed: UInt64) {
        self.state = seed
    }

    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    package mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    package mutating func unitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
