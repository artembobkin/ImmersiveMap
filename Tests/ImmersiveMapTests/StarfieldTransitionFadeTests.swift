// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class StarfieldTransitionFadeTests: XCTestCase {
    func testStarfieldBackgroundFadesTowardMapColorDuringGlobeTransition() throws {
        let source = try starfieldShaderSource()

        XCTAssertTrue(source.contains("transitionTargetColor"))
        XCTAssertTrue(source.contains("half transitionFade = smoothstep(0.0h, 1.0h, half(globe.transition));"))
        XCTAssertTrue(source.contains("color = mix(color, half3(params.transitionTargetColor.rgb), transitionFade);"))
    }

    func testStarfieldStarsFadeOutDuringGlobeTransition() throws {
        let source = try starfieldShaderSource()

        XCTAssertTrue(source.contains("half transitionAlpha = 1.0h - smoothstep(0.0h, 1.0h, in.transition);"))
        XCTAssertTrue(source.contains("half alpha = saturate(core * 0.95h + halo * 0.55h + crossGlow) * intensity * transitionAlpha;"))
        XCTAssertTrue(source.contains("half3 emissive = color * (core * 1.3h + halo * 0.75h + crossGlow * 1.6h) * intensity * transitionAlpha;"))
    }

    func testStarfieldRendererUsesMapClearColorAsTransitionTarget() throws {
        let source = try starfieldRendererSource()

        XCTAssertTrue(source.contains("transitionTargetColor: SIMD4<Double>"))
        XCTAssertTrue(source.contains("transitionTargetColor: transitionTargetColor"))
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

    private func starfieldRendererSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Starfield/StarfieldRenderer.swift")
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}
