// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Pins the byte layout of the Swift mirrors of SceneModel.metal structs and
/// the canonical vertex layout produced by SceneModelAssetLoader: a drifted
/// stride or offset would silently corrupt every draw.
final class SceneModelGPUStructLayoutTests: XCTestCase {
    func testLightUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<SceneModelDrawer.SceneModelLightUniform>.stride, 48)
        XCTAssertEqual(MemoryLayout<SceneModelDrawer.SceneModelLightUniform>.offset(of: \.direction), 0)
        XCTAssertEqual(MemoryLayout<SceneModelDrawer.SceneModelLightUniform>.offset(of: \.color), 16)
        XCTAssertEqual(MemoryLayout<SceneModelDrawer.SceneModelLightUniform>.offset(of: \.intensities), 32)
    }

    func testMaterialUniformMatchesMetalLayout() {
        XCTAssertEqual(MemoryLayout<SceneModelDrawer.SceneModelMaterialUniform>.stride, 16)
        XCTAssertEqual(MemoryLayout<SceneModelDrawer.SceneModelMaterialUniform>.offset(of: \.baseColor), 0)
    }

    func testMatrixUniformsMatchMetalLayout() {
        // float4x4 and float3x3 setVertexBytes payloads.
        XCTAssertEqual(MemoryLayout<matrix_float4x4>.stride, 64)
        XCTAssertEqual(MemoryLayout<simd_float3x3>.stride, 48)
    }

    func testCanonicalVertexLayoutIsPinned() {
        XCTAssertEqual(SceneModelAssetLoader.vertexStride, 32)
        XCTAssertEqual(SceneModelAssetLoader.normalOffset, 12)
        XCTAssertEqual(SceneModelAssetLoader.uvOffset, 24)
    }
}
