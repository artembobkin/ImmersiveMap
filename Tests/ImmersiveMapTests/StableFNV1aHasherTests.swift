// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class StableFNV1aHasherTests: XCTestCase {
    func testCombinesUTF8StringsUsingExistingCacheFingerprintSemantics() {
        var hasher = StableFNV1aHasher()

        hasher.combine("openstreetmap")
        hasher.combine("openstreetmap-shortbread-v1")
        hasher.combine("https://vector.openstreetmap.org/shortbread_v1")
        hasher.combine("12345")

        XCTAssertEqual(hasher.finalize(), 0x5dd5dffaf5b50db3)
    }
}
