// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class StarfieldTransitionFadeTests: XCTestCase {
    /// Space is the world pass's clear color, and the unfurl fades it toward
    /// the flat map's color there: exactly the space color at transition 0,
    /// exactly the map color at 1, strictly between in the middle.
    func testSpaceClearColorBlendsTowardMapColorDuringGlobeTransition() {
        let settings = ImmersiveMapSettings.default
        let space = settings.scene.space.clearColor
        let map = settings.scene.mapClearColor

        let sphere = RenderFrameClearColor.make(transition: 0, settings: settings)
        XCTAssertEqual(sphere.red, space.x, accuracy: 1e-9)
        XCTAssertEqual(sphere.green, space.y, accuracy: 1e-9)
        XCTAssertEqual(sphere.blue, space.z, accuracy: 1e-9)

        let flat = RenderFrameClearColor.make(transition: 1, settings: settings)
        XCTAssertEqual(flat.red, map.x, accuracy: 1e-9)
        XCTAssertEqual(flat.green, map.y, accuracy: 1e-9)
        XCTAssertEqual(flat.blue, map.z, accuracy: 1e-9)

        let mid = RenderFrameClearColor.make(transition: 0.5, settings: settings)
        XCTAssertEqual(mid.red, (space.x + map.x) * 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.green, (space.y + map.y) * 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.blue, (space.z + map.z) * 0.5, accuracy: 1e-9)
    }

    func testStarfieldStarsFadeOutDuringGlobeTransition() throws {
        let source = try starfieldShaderSource()

        XCTAssertTrue(source.contains("half transitionAlpha = 1.0h - smoothstep(0.0h, 1.0h, in.transition);"))
        XCTAssertTrue(source.contains("half alpha = saturate(core * 0.95h + halo * 0.55h + crossGlow) * intensity * transitionAlpha;"))
        XCTAssertTrue(source.contains("half3 emissive = color * (core * 1.3h + halo * 0.75h + crossGlow * 1.6h) * intensity * transitionAlpha;"))
    }

    private func starfieldShaderSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Shaders/Starfield/StarfieldStars.metal")
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}
