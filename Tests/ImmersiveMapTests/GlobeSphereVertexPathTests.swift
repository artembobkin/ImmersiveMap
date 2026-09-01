// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd
@testable import ImmersiveMap
import XCTest

/// At transition 0 the globe surface IS the sphere, and the vertex stages
/// fold away the flat morph target, the unfurl phase and the mix through a
/// function-constant specialization fed by per-frame constants computed on
/// the CPU. These tests pin the gate, the uniform layout the shaders read,
/// and the shader-source contract.
final class GlobeSphereVertexPathTests: XCTestCase {
    func testThePureSphereIsTransitionZeroOnTheSphere() {
        XCTAssertTrue(GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: .spherical, transition: 0))
    }

    func testTheMorphTakesTheFullPath() {
        XCTAssertFalse(GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: .spherical, transition: 0.01))
    }

    func testTheFlatWorldNeverTakesIt() {
        XCTAssertFalse(GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: .flat, transition: 1))
    }


    // MARK: - The uniform the shaders read

    /// The Swift mirror must lay out exactly as `GlobeFrameConstants` in
    /// RenderUniforms.h: the matrix, then four floats filling one 16-byte
    /// row.
    func testFrameConstantsLayoutMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.rotation), 0)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.sphereClip), 64)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.sphereWorld), 128)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.mapSize), 192)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panMercatorY), 196)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panLatitude), 200)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.panLongitude), 204)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.offset(of: \.curvature), 208)
        XCTAssertEqual(MemoryLayout<GlobeFrameConstantsUniform>.stride, 240)
    }

    /// The frame constants mirror the shader helpers term for term: the pan
    /// angles, the map size mix and the rotation columns match what
    /// `GeoScreenProjectionMath.FrameConstants` (the established CPU mirror
    /// of the same shader math) computes for the same globe.
    func testFrameConstantsMirrorTheProjectionMathMirror() {
        let globe = GlobeUniform(panX: 0.3, panY: -0.2, radius: 1000, transition: 0.4)
        let uniform = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: matrix_identity_float4x4)

        let panLatitude = globe.panY * Float(ImmersiveMapProjection.maxMercatorLatitude)
        let panLongitude = globe.panX * Float.pi
        XCTAssertEqual(uniform.panLatitude, panLatitude)
        XCTAssertEqual(uniform.panLongitude, panLongitude)
        let mapSizeScale = (1.0 - globe.transition) * cos(panLatitude) + globe.transition
        XCTAssertEqual(uniform.mapSize, 2.0 * Float.pi * globe.radius * mapSizeScale)
        XCTAssertEqual(uniform.panMercatorY,
                       Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude))))
        // The row-vector layout the shaders multiply with: transposing it
        // must give the matrix the CPU-side projector uses column-style.
        XCTAssertEqual(uniform.rotation.columns.0, SIMD4<Float>(cos(-panLongitude), 0, -sin(-panLongitude), 0))
        XCTAssertEqual(uniform.rotation.columns.3, SIMD4<Float>(0, 0, 0, 1))
    }

    // MARK: - Shader source contract

    /// The sphere is drawn by two dedicated vertex stages: the resting
    /// sphere through the composed sphereClip matrix, the unfurl through the
    /// unroll, both consuming the frame constants.
    func testTheSphereVertexStagesAreSplitByWorld() throws {
        let sphere = try shaderSource("Render/Tiles/Shaders/TileSphere.metal")
        XCTAssertTrue(sphere.contains("vertex SphereVertexOut tileSpherePureVertexShader("))
        XCTAssertTrue(sphere.contains("vertex SphereMorphVertexOut tileSphereMorphVertexShader("))
        XCTAssertTrue(sphere.contains("globeFrame.sphereClip * float4(unitDirection, 1.0)"))
        XCTAssertTrue(sphere.contains("globeUnrollWorldPosition("))
        XCTAssertTrue(sphere.contains("constant GlobeFrameConstants& globeFrame [[buffer(10)]]"))
        let unroll = try shaderSource("Render/Shaders/Globe/GlobeUnroll.h")
        XCTAssertTrue(unroll.contains("static inline float3 globeUnrollWorldPosition("))
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
}
