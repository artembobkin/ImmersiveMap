// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// What the horizon shader promises the rest of the world pass: it sits at
/// the far plane (the two depth tests of the layer compare against it), it
/// never discards (a fullscreen discard would defeat hidden surface removal
/// for every later layer of the pass), it carries the side switch as a
/// function constant, and the sky profile's weights are the ones the CPU
/// side documents. Reads the shader source off the checkout, so it cannot
/// run on a device.
final class HorizonShaderContractTests: XCTestCase {
    func testTheShaderSitsAtTheFarPlaneAndNeverDiscards() throws {
        let source = try shaderSource()
        XCTAssertNil(source.range(of: "discard_fragment"))
        XCTAssertTrue(source.contains("out.position = float4(positions[vertexID], 1.0, 1.0);"),
                      "The fullscreen triangle rasterizes at the far plane")
        XCTAssertTrue(source.contains("constant bool kHorizonGroundSide [[function_constant(0)]];"))
        XCTAssertTrue(source.contains("above = min(above, 0.0);"),
                      "The ground side clamps its angle to the edge")
        XCTAssertNil(source.range(of: "texture2d"), "Pure arithmetic: no texture reads")
    }

    func testTheProfileWeightsArePinned() throws {
        let source = try shaderSource()
        XCTAssertTrue(source.contains("constant float kHorizonBandWeight = 0.85;"))
        XCTAssertTrue(source.contains("constant float kHorizonGlowWeight = 0.22;"))
    }

    /// The angle formula the CPU mirrors, term for term.
    func testTheEdgeAngleIsTheMirroredFormula() throws {
        let source = try shaderSource()
        XCTAssertTrue(source.contains("return asin(clamp(dot(direction, horizon.up), -1.0, 1.0)) + horizon.depression;"))
    }

    private func shaderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("ImmersiveMap/Render/Shaders/Horizon/Horizon.metal")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
