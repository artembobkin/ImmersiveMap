// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest

final class StarfieldTransitionFadeTests: XCTestCase {
    func testStarfieldBackgroundFadesTowardMapColorDuringGlobeTransition() throws {
        let source = try starfieldShaderSource()

        XCTAssertTrue(source.contains("transitionTargetColor"))
        XCTAssertTrue(source.contains("float transitionFade = smoothstep(0.0, 1.0, globe.transition);"))
        XCTAssertTrue(source.contains("color = mix(color, params.transitionTargetColor.rgb, transitionFade);"))
    }

    func testStarfieldStarsFadeOutDuringGlobeTransition() throws {
        let source = try starfieldShaderSource()

        XCTAssertTrue(source.contains("float transitionAlpha = 1.0 - smoothstep(0.0, 1.0, in.transition);"))
        XCTAssertTrue(source.contains("float alpha = saturate(core * 0.95 + halo * 0.55 + crossGlow) * intensity * transitionAlpha;"))
        XCTAssertTrue(source.contains("float3 emissive = color * (core * 1.3 + halo * 0.75 + crossGlow * 1.6) * intensity * transitionAlpha;"))
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
