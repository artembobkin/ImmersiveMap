// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class StarfieldTransitionFadeTests: XCTestCase {
    /// Space is the world pass's clear color for as long as the surface is
    /// the sphere, the unroll included; the map's color takes over exactly
    /// at the surface switch. Nothing in between: a blend would show as a
    /// grey sky brightening behind the stars while the world unrolls.
    func testSpaceClearColorHoldsUntilTheSurfaceSwitch() {
        let settings = ImmersiveMapSettings.default
        let space = settings.scene.space.clearColor
        let map = settings.scene.mapClearColor

        for transition in [Float(0), 0.5, 0.95, 0.999] {
            let sphere = RenderFrameClearColor.make(transition: transition, settings: settings)
            XCTAssertEqual(sphere.red, space.x, accuracy: 1e-9, "at \(transition)")
            XCTAssertEqual(sphere.green, space.y, accuracy: 1e-9, "at \(transition)")
            XCTAssertEqual(sphere.blue, space.z, accuracy: 1e-9, "at \(transition)")
        }

        let flat = RenderFrameClearColor.make(transition: 1, settings: settings)
        XCTAssertEqual(flat.red, map.x, accuracy: 1e-9)
        XCTAssertEqual(flat.green, map.y, accuracy: 1e-9)
        XCTAssertEqual(flat.blue, map.z, accuracy: 1e-9)
    }

    /// The stars keep their full strength through the unroll: the shader
    /// carries no transition fade any more.
    func testStarfieldStarsDoNotFadeDuringGlobeTransition() throws {
        let source = try starfieldShaderSource()

        XCTAssertNil(source.range(of: "transitionAlpha"))
        XCTAssertNil(source.range(of: "in.transition"))
        XCTAssertTrue(source.contains("half alpha = saturate(core * 0.95h + halo * 0.55h + crossGlow) * intensity;"))
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
