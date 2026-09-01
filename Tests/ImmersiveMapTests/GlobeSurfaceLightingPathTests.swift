// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The deferred surface lighting runs only while `globeSurfaceShade` is an
/// affine transform of the colour, which is when lighting once after the
/// blend equals lighting every layer before it: the pure sphere (no fog, no
/// morphed silhouette). These tests pin that gate and the uniform layout
/// the pass hands the shader.
final class GlobeSurfaceLightingPathTests: XCTestCase {
    func testThePureSphereDefers() {
        XCTAssertTrue(GlobeSurfaceLightingPath.isDeferred(renderSurfaceMode: .spherical,
                                                          transition: 0))
    }

    /// The unfurl brings the fog (its strength is the transition) and a
    /// silhouette that is no longer the sphere's: every layer lights itself.
    func testTheMorphLightsInline() {
        XCTAssertFalse(GlobeSurfaceLightingPath.isDeferred(renderSurfaceMode: .spherical,
                                                           transition: 0.01))
    }

    func testTheFlatWorldNeverDefers() {
        XCTAssertFalse(GlobeSurfaceLightingPath.isDeferred(renderSurfaceMode: .flat,
                                                           transition: 1))
    }

    /// The unlit variants carry no lighting varyings: the members exist
    /// only when the constant lights inline, so the unlit specialization
    /// neither exports, interpolates nor loads them.
    func testUnlitVariantsCarryNoLightingVaryings() throws {
        let sphere = try shaderSource("Render/Tiles/Shaders/TileSphere.metal")
        XCTAssertTrue(sphere.contains("float3 worldPos [[function_constant(kTileSphereLitInline)]];"))
        XCTAssertTrue(sphere.contains("float3 normal [[function_constant(kTileSphereLitInline)]];"))
        XCTAssertTrue(sphere.contains("float3 earthNormal [[function_constant(kTileSphereLitInline)]];"))
        XCTAssertTrue(sphere.contains("float transition [[function_constant(kTileSphereLitInline)]];"))
        let globe = try shaderSource("Render/Shaders/Globe/Globe.metal")
        XCTAssertTrue(globe.contains("float3 worldPos [[function_constant(kGlobePlaceholderLitInline)]];"))
        XCTAssertTrue(globe.contains("float3 normal [[function_constant(kGlobePlaceholderLitInline)]];"))
        XCTAssertTrue(globe.contains("float3 earthNormal [[function_constant(kGlobePlaceholderLitInline)]];"))
        XCTAssertTrue(globe.contains("float transition [[function_constant(kGlobePlaceholderLitInline)]];"))
    }

    /// Reads a shader off the checkout, the way the other shader-source
    /// tests do; on a physical device there is no checkout and these tests
    /// are filtered out rather than run.
    private func shaderSource(_ relativePath: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shaderURL = packageRootURL.appendingPathComponent("ImmersiveMap/" + relativePath)
        return try String(contentsOf: shaderURL, encoding: .utf8)
    }

    /// The Swift mirror must lay out exactly as the Metal struct at
    /// buffer 0: the matrix, then three padded float3 fields, then the
    /// radius.
    func testUniformLayoutMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<GlobeSurfaceLightingUniform>.offset(of: \.inverseViewProjection), 0)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceLightingUniform>.offset(of: \.eye), 64)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceLightingUniform>.offset(of: \.center), 80)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceLightingUniform>.offset(of: \.worldSunDirection), 96)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceLightingUniform>.offset(of: \.radius), 112)
        XCTAssertEqual(MemoryLayout<GlobeSurfaceLightingUniform>.stride, 128)
    }
}
