// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class TextShaderStrokeClampTests: XCTestCase {
    func testShaderUsesTriplePrecisionTextAtlasRange() throws {
        let source = try textShaderSource()

        XCTAssertFalse(source.contains("float2(8.0)"))
        XCTAssertFalse(source.contains("const float distanceRange = 8.0"))
        XCTAssertTrue(source.contains("const float distanceRange = 24.0"))
        XCTAssertTrue(source.contains("float2(distanceRange)"))
    }

    func testShaderUsesMtsdfAlphaForStrokeDistance() throws {
        let source = try textShaderSource()

        XCTAssertTrue(source.contains("atlasSample.a"))
        XCTAssertTrue(source.contains("sdfPxDist"))
        XCTAssertTrue(source.contains("half outer = half(smoothstep(-strokeWidthPx - 0.5, -strokeWidthPx + 0.5, distance.sdfPxDist));"))
    }

    /// A class that asks for no halo (the POIs) must get none: fill and outer
    /// edge come from two different distance fields, so their difference at
    /// zero width is not reliably zero.
    func testAZeroWidthStrokeIsSkippedRatherThanDifferenced() throws {
        let source = try textShaderSource()

        XCTAssertTrue(source.contains("half stroke = strokeWidthPx > 0.0 ? clamp(outer - fill, 0.0h, 1.0h) : 0.0h;"))
    }

    func testBaseTextFragmentCapsStrokeBeforeItFillsGlyphQuad() throws {
        let source = try textShaderSource()
        let baseFragmentSource = try XCTUnwrap(source.components(separatedBy: "fragment half4 roadTextFragment").first)

        XCTAssertFalse(baseFragmentSource.contains("max(distance.screenPxRange - 0.75, 0.75)"))
        XCTAssertTrue(baseFragmentSource.contains("max(0.5 * distance.screenPxRange - 0.5, 0.0)"))
    }

    private func textShaderSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Text/Shaders/TextShader.metal")
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}
