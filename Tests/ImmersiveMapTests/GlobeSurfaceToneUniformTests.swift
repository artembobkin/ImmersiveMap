// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

final class GlobeSurfaceToneUniformTests: XCTestCase {
    /// Mirror of `GlobeSurfaceTone` in RenderUniforms.h: one float padded to
    /// a 16-byte constant.
    func testUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<GlobeSurfaceToneUniform>.stride, 16)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceToneUniform>.offset(of: \.depth), 0)
    }

    /// The colours are deepest with the whole planet on screen and ease back
    /// to the tile palette between zoom 1 and 2: full up to zoom 1, halfway
    /// at 1.5, gone at zoom 2, flat outside the ramp.
    func testDepthEasesOutBetweenZoomOneAndTwo() {
        XCTAssertEqual(GlobeSurfaceToneUniform.deepZoom, 1)
        XCTAssertEqual(GlobeSurfaceToneUniform.plainZoom, 2)

        XCTAssertEqual(GlobeSurfaceToneUniform.make(zoom: -1).depth, 1, accuracy: 1e-6)
        XCTAssertEqual(GlobeSurfaceToneUniform.make(zoom: 0).depth, 1, accuracy: 1e-6)
        XCTAssertEqual(GlobeSurfaceToneUniform.make(zoom: 1).depth, 1, accuracy: 1e-6)
        XCTAssertEqual(GlobeSurfaceToneUniform.make(zoom: 1.5).depth, 0.5, accuracy: 1e-6)
        XCTAssertEqual(GlobeSurfaceToneUniform.make(zoom: 2).depth, 0, accuracy: 1e-6)
        XCTAssertEqual(GlobeSurfaceToneUniform.make(zoom: 5).depth, 0, accuracy: 1e-6)
        XCTAssertEqual(GlobeSurfaceToneUniform.make(zoom: .nan).depth, 0)

        // Monotonic through the ramp, and smooth at both ends: the first and
        // last step are smaller than the one in the middle.
        let samples = stride(from: 1.0, through: 2.0, by: 0.125).map { GlobeSurfaceToneUniform.depth(zoom: $0) }
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThan(previous, next)
        }
        let firstStep = samples[0] - samples[1]
        let middleStep = samples[3] - samples[4]
        let lastStep = samples[7] - samples[8]
        XCTAssertLessThan(firstStep, middleStep)
        XCTAssertLessThan(lastStep, middleStep)
    }

    /// The deepening is one look on the whole sphere: the tile geometry, the
    /// placeholder fill under a still-loading tile and the polar caps all
    /// bind the tone and run the same function, otherwise a tile that has not
    /// arrived, or the pole, would show in the paler palette next to the rest.
    func testTiledSurfacePlaceholderAndCapsShareTheDeepening() throws {
        // The shared surface shade lives in its own header (the tile
        // geometry drawn on the sphere shares it too); the cap keeps its own
        // call in Globe.metal.
        let source = try shaderSource("Render/Shaders/Globe/Globe.metal")
            + shaderSource("Render/Shaders/Globe/GlobeSurfaceShading.h")

        XCTAssertEqual(source.components(separatedBy: "constant GlobeSurfaceTone& tone [[buffer(7)]]").count - 1, 2,
                       "The placeholder fill and the cap each bind the tone")
        let sphereSource = try shaderSource("Render/Tiles/Shaders/TileSphere.metal")
        XCTAssertEqual(sphereSource.components(separatedBy: "constant GlobeSurfaceTone& tone [[buffer(8)]]").count - 1, 1,
                       "The tile geometry drawn on the sphere binds the tone")
        XCTAssertEqual(source.components(separatedBy: "globeSurfaceDeepen(color.rgb, facingDot, tone)").count - 1, 2,
                       "The shared surface shade and the cap both deepen the colour")

        // It works on the bare sampled colour: before the day/night shading,
        // before the glow is added, so those keep their own look on top.
        let shade = try XCTUnwrap(source.range(of: "static inline half4 globeSurfaceShade("))
        let body = source[shade.lowerBound...]
        let deepen = try XCTUnwrap(body.range(of: "globeSurfaceDeepen(color.rgb, facingDot, tone)"))
        let shading = try XCTUnwrap(body.range(of: "earthScene.isEnabled != 0"))
        XCTAssertLessThan(deepen.lowerBound, shading.lowerBound)
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRootURL.appendingPathComponent("ImmersiveMap").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
