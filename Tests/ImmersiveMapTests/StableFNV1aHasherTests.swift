// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class StableFNV1aHasherTests: XCTestCase {
    func testCombinesUTF8StringsUsingExistingCacheFingerprintSemantics() {
        var hasher = StableFNV1aHasher()

        hasher.combine("immersivemap")
        hasher.combine("immersivemaptiles")
        hasher.combine("https://tiles.immersivemap.dev")
        hasher.combine("12345")

        XCTAssertEqual(hasher.finalize(), 0xaeea2c1e559c60a3)
    }
}
