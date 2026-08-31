// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The sky (the space background, the stars, the Sun and the atmosphere halo)
/// draws after the globe surface, rasterized at the far plane and depth-tested
/// against the surface depth the globe wrote: a pixel the sphere covered
/// rejects the sky fragment before it shades, instead of the sky painting the
/// whole screen first and being painted over. These tests pin the two halves
/// of that contract: the planner's order, and the far-plane positions in the
/// sky shaders that make the depth test mean "space only".
final class SkyBackdropDepthTests: XCTestCase {
    func testPlannerDrawsTheSurfaceBeforeTheSky() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 sceneModelOcclusionEnabled: false,
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
        ).map(\.layer)

        let surface = try! XCTUnwrap(plan.firstIndex(of: .globeSurface))
        let tiles = try! XCTUnwrap(plan.firstIndex(of: .globeVectorSurface))
        let starfield = try! XCTUnwrap(plan.firstIndex(of: .starfield))
        let atmosphere = try! XCTUnwrap(plan.firstIndex(of: .atmosphere))
        let cap = try! XCTUnwrap(plan.firstIndex(of: .globeCap))
        XCTAssertLessThan(surface, starfield, "The surface depth must exist before the sky tests against it")
        XCTAssertLessThan(tiles, starfield, "The tile geometry is part of the surface the sky is clipped by")
        XCTAssertLessThan(starfield, atmosphere, "The halo blends over the stars, so it draws after them")
        // The poles lie outside the Mercator slots: no grid depth covers
        // them, so the caps draw after the sky and paint over it there.
        XCTAssertLessThan(atmosphere, cap, "The polar caps paint over the sky, which cannot reject them by depth")
    }

    /// The fullscreen sky triangles (the space background, the Sun) sit at the
    /// far plane, where the depth test passes only against a cleared pixel.
    func testStarfieldFullscreenTrianglesSitAtTheFarPlane() throws {
        let source = try shaderSource("Starfield/StarfieldStars.metal")

        XCTAssertTrue(source.contains("out.position = float4(clip, 1.0, 1.0);"))
        XCTAssertFalse(source.contains("float4(clip, 0.0, 1.0)"))
    }

    /// The stars render through their own projection, so their depth is not
    /// comparable to the surface's; they are forced to the far plane too.
    func testStarsAreForcedToTheFarPlane() throws {
        let source = try shaderSource("Starfield/StarfieldStars.metal")

        XCTAssertTrue(source.contains("out.position.z = out.position.w;"))
    }

    func testAtmosphereTriangleSitsAtTheFarPlane() throws {
        let source = try shaderSource("Atmosphere/Atmosphere.metal")

        XCTAssertTrue(source.contains("out.position = float4(positions[vertexID], 1.0, 1.0);"))
        XCTAssertFalse(source.contains("float4(positions[vertexID], 0.0, 1.0)"))
    }

    /// Reads a shader off the checkout, the way the other shader-source tests
    /// do; on a physical device there is no checkout and these tests are
    /// filtered out rather than run.
    private func shaderSource(_ relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/Render/Shaders/" + relativePath)
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }
}
