// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TerrainRGBDecoderTests: XCTestCase {
    func testMapboxTerrainRGBDecodesZeroMeters() {
        let height = TerrainRGBDecoder.heightMeters(r: 1, g: 134, b: 160, encoding: .mapboxTerrainRGB)

        XCTAssertEqual(height, 0, accuracy: 0.0001)
    }

    func testMapboxTerrainRGBDecodesKnownPositiveHeight() {
        let height = TerrainRGBDecoder.heightMeters(r: 1, g: 158, b: 16, encoding: .mapboxTerrainRGB)

        XCTAssertEqual(height, 600, accuracy: 0.0001)
    }

    func testTerrariumDecodesZeroMeters() {
        let height = TerrainRGBDecoder.heightMeters(r: 128, g: 0, b: 0, encoding: .terrarium)

        XCTAssertEqual(height, 0, accuracy: 0.0001)
    }
}
