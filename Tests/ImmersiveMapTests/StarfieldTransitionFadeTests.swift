// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class StarfieldTransitionFadeTests: XCTestCase {
    /// Space is the world pass's clear color for as long as the surface is
    /// the sphere, up to the air handover of the unroll. Over the handover
    /// it brightens into the map's colour at the pace the flat map's sky
    /// fades in over the stars, and from the handover's end on, the surface
    /// switch included, it is the map's colour, so the switch changes
    /// nothing.
    func testSpaceClearColorBlendsIntoTheMapColorOverTheAirHandover() {
        let settings = ImmersiveMapSettings.default
        let presentation = settings.presentation
        let space = settings.scene.space.clearColor
        let mapColor = ProtomapsBasemapTheme.default.baseColors.map
        let map = SIMD4<Double>(Double(mapColor.x), Double(mapColor.y), Double(mapColor.z), Double(mapColor.w))

        for transition in [Float(0), 0.5, presentation.airHandoverStart] {
            let sphere = RenderFrameClearColor.make(transition: transition, settings: settings, mapColor: mapColor)
            XCTAssertEqual(sphere.red, space.x, accuracy: 1e-9, "at \(transition)")
            XCTAssertEqual(sphere.green, space.y, accuracy: 1e-9, "at \(transition)")
            XCTAssertEqual(sphere.blue, space.z, accuracy: 1e-9, "at \(transition)")
        }

        let midway = (presentation.airHandoverStart + presentation.airHandoverEnd) / 2
        let blended = RenderFrameClearColor.make(transition: midway, settings: settings, mapColor: mapColor)
        XCTAssertEqual(blended.red, (space.x + map.x) / 2, accuracy: 1e-6)
        XCTAssertEqual(blended.green, (space.y + map.y) / 2, accuracy: 1e-6)
        XCTAssertEqual(blended.blue, (space.z + map.z) / 2, accuracy: 1e-6)

        for transition in [presentation.airHandoverEnd, 0.95, 0.999, 1] {
            let flat = RenderFrameClearColor.make(transition: transition, settings: settings, mapColor: mapColor)
            XCTAssertEqual(flat.red, map.x, accuracy: 1e-9, "at \(transition)")
            XCTAssertEqual(flat.green, map.y, accuracy: 1e-9, "at \(transition)")
            XCTAssertEqual(flat.blue, map.z, accuracy: 1e-9, "at \(transition)")
        }
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
        let shaderURL = packageRootURL.appendingPathComponent("Sources/ImmersiveMap/Starfield/Shaders/StarfieldStars.metal")
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}
