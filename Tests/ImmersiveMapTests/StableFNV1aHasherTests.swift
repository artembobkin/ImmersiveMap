// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class StableFNV1aHasherTests: XCTestCase {
    func testCombinesUTF8StringsUsingExistingCacheFingerprintSemantics() {
        var hasher = StableFNV1aHasher()

        hasher.combine("immersivemap")
        hasher.combine("protomaps")
        hasher.combine("https://tiles.immersivemap.dev")
        hasher.combine("12345")

        XCTAssertEqual(hasher.finalize(), 0xdc9e7f144eae4bdc)
    }
}
