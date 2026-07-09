// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class AvatarRenderShaderShapeTests: XCTestCase {
    func testAvatarFragmentUsesOnlyMarkerSDFShape() throws {
        let source = try avatarRenderShaderSource()

        XCTAssertFalse(source.contains("circleShape"))
        XCTAssertFalse(source.contains("flags & 2u"))
        XCTAssertTrue(source.contains("decodeSignedDistanceTexels"))
        XCTAssertTrue(source.contains("sdfTexture.sample"))
    }

    func testBadgeVerticesApplyPerAvatarScreenSizeScale() throws {
        let source = try avatarRenderShaderSource()

        XCTAssertTrue(source.contains("instance.screenSizeScale"))
        XCTAssertTrue(source.contains("style.sizePx.x * screenSizeScale"))
        XCTAssertTrue(source.contains("style.originXPx * screenSizeScale"))
    }

    func testAvatarFragmentsApplyScreenPointVisibilityAlpha() throws {
        let source = try avatarRenderShaderSource()

        XCTAssertTrue(source.contains("out.visibilityAlpha = point.visibilityAlpha"))
        XCTAssertTrue(source.contains("color.a = alpha * in.visibilityAlpha"))
        XCTAssertTrue(source.contains("color.a *= in.visibilityAlpha"))
    }

    private func avatarRenderShaderSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Avatars/Shaders/AvatarRender.metal")
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}
