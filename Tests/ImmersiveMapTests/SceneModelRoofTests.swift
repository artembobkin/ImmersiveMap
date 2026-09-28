// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A drawn model's top over the ground, the roof of the building it stands
/// for, which the labels in that building take in place of the tile's.
final class SceneModelRoofTests: XCTestCase {
    /// The asset's Y-up box turned Z-up and placed: the footprint is the
    /// box's X and Z, the top is its Y, scaled and moved with the model.
    func testTheRoofIsTheBoundsCarriedIntoTheWorld() {
        let bounds = SceneModelMesh.Bounds(minimum: SIMD3(-1, 0, -2), maximum: SIMD3(1, 30, 2))
        let modelMatrix = Matrix.translationMatrix(x: 100, y: 200, z: 0)
            * Matrix.rotationMatrixX(.pi / 2)
            * Matrix.scaleMatrix(sx: 2, sy: 2, sz: 2)
        let roof = SceneModelRoof(modelMatrix: modelMatrix, bounds: bounds)

        XCTAssertEqual(roof.top, 60, accuracy: 1e-3)
        XCTAssertEqual(roof.minimum.x, 98, accuracy: 1e-3)
        XCTAssertEqual(roof.maximum.x, 102, accuracy: 1e-3)
        XCTAssertEqual(roof.minimum.y, 196, accuracy: 1e-3)
        XCTAssertEqual(roof.maximum.y, 204, accuracy: 1e-3)
    }

    /// The tallest roof over the point wins, and the floor stands where no
    /// roof covers the point or none reaches above it.
    func testTheTallestRoofOverThePointWinsOverTheFloor() {
        let roofs = [SceneModelRoof(minimum: SIMD2(0, 0), maximum: SIMD2(10, 10), top: 5),
                     SceneModelRoof(minimum: SIMD2(5, 5), maximum: SIMD2(20, 20), top: 8)]

        XCTAssertEqual(SceneModelRoof.height(over: SIMD2(2, 2), roofs: roofs, floor: 0), 5)
        XCTAssertEqual(SceneModelRoof.height(over: SIMD2(7, 7), roofs: roofs, floor: 0), 8)
        XCTAssertEqual(SceneModelRoof.height(over: SIMD2(7, 7), roofs: roofs, floor: 12), 12,
                       "the tile's own roof stands where it is higher than the model")
        XCTAssertEqual(SceneModelRoof.height(over: SIMD2(30, 30), roofs: roofs, floor: 3), 3)
    }
}
