// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

final class GlobeAtlasPlanCacheKeyTests: XCTestCase {
    func testKeyIsStableForUnchangedAtlasInputs() {
        let first = makeKey()
        let second = makeKey()

        XCTAssertEqual(first, second)
    }

    func testKeyChangesWhenPlacementVersionChanges() {
        let first = makeKey(placementVersion: 1)
        let second = makeKey(placementVersion: 2)

        XCTAssertNotEqual(first, second)
    }

    func testKeyChangesWhenCameraProjectionChanges() {
        let first = makeKey(matrixScale: 1)
        let second = makeKey(matrixScale: 2)

        XCTAssertNotEqual(first, second)
    }

    func testKeyChangesWhenGlobeUniformChanges() {
        let first = makeKey(globePanX: 0)
        let second = makeKey(globePanX: 0.25)

        XCTAssertNotEqual(first, second)
    }

    private func makeKey(placementVersion: UInt64 = 1,
                         matrixScale: Float = 1,
                         globePanX: Float = 0) -> GlobeAtlasPlanCacheKey {
        GlobeAtlasPlanCacheKey(
            renderSurfaceMode: .spherical,
            placementVersion: placementVersion,
            drawSize: CGSize(width: 390, height: 844),
            cameraUniform: CameraUniform(
                matrix: matrix_float4x4(diagonal: SIMD4<Float>(matrixScale, matrixScale, matrixScale, 1)),
                eye: SIMD3<Float>(0, 0, 4),
                padding: 0
            ),
            globe: GlobeUniform(panX: globePanX,
                                panY: 0,
                                radius: 128,
                                transition: 0),
            textureSize: 4096,
            qualityScale: 1
        )
    }
}
