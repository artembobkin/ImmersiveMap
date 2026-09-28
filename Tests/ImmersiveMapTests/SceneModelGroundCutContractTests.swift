// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The ground cut of a scene model (SceneModel.metal): its stencil bit has
/// to stay out of the tile priority, the road sheet's bit and the surface
/// mask, and the ground plane the shader reads has to be laid out as the
/// Swift mirror is. The plane's values are checked with the anchor math
/// (SceneModelAnchorMathTests).
final class SceneModelGroundCutContractTests: XCTestCase {
    func testTheGroundHoleBitSitsOutsideEveryOtherStencilUse() {
        let bit = TileSourceStencilPriority.groundHoleBit
        XCTAssertEqual(bit & TileSourceStencilPriority.priorityMask, 0)
        XCTAssertEqual(bit & TileSourceStencilPriority.roadSheetBit, 0)
        XCTAssertEqual(bit & TileSourceStencilPriority.surfaceMaskBit, 0)
        XCTAssertEqual(bit.nonzeroBitCount, 1)
        XCTAssertLessThanOrEqual(bit, 0xFF, "the stencil is eight bits")
    }

    func testSwiftAndMetalGroundPlanesAgree() throws {
        // Two float3 fields, each 16 bytes in a constant buffer.
        XCTAssertEqual(MemoryLayout<SceneModelGroundPlane>.stride, 32)
        XCTAssertEqual(MemoryLayout<SceneModelGroundPlane>.offset(of: \.up), 16)
        let source = try shaderSource("SceneModels/Shaders/SceneModel.metal")
        let structRange = try XCTUnwrap(source.range(of: "struct SceneModelGroundPlane {"))
        let body = source[structRange.upperBound...].prefix(while: { $0 != "}" })
        let fields = body.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        XCTAssertEqual(fields, ["float3 surfacePosition", "float3 up"])
    }

    private func shaderSource(_ relativePath: String) throws -> String {
        let packageRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRootURL.appendingPathComponent("Sources/ImmersiveMap").appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
