// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileCoverageZoomPolicyTests: XCTestCase {
    func testFlatModeKeepsSingleCoverageZoomAtFlooredCameraZoom() {
        let plan = TileCoverageZoomPolicy.resolve(cameraZoom: 1.74,
                                                  renderSurfaceMode: .flat,
                                                  maximumZoomLevel: 20)

        XCTAssertEqual(plan.baseZoom, 1)
    }

    func testGlobeModeKeepsSingleCoverageZoomAtFlooredCameraZoom() {
        let plan = TileCoverageZoomPolicy.resolve(cameraZoom: 1.74,
                                                  renderSurfaceMode: .spherical,
                                                  maximumZoomLevel: 20)

        XCTAssertEqual(plan.baseZoom, 1)
    }

    func testGlobeModeDoesNotRequestAheadDetailZoomNearMaximumZoom() {
        let plan = TileCoverageZoomPolicy.resolve(cameraZoom: 19.7,
                                                  renderSurfaceMode: .spherical,
                                                  maximumZoomLevel: 20)

        XCTAssertEqual(plan.baseZoom, 19)
    }

    func testGlobeDoesNotCreateDuplicateDetailZoomWhenBaseAlreadyAtMaximum() {
        let plan = TileCoverageZoomPolicy.resolve(cameraZoom: 20.0,
                                                  renderSurfaceMode: .spherical,
                                                  maximumZoomLevel: 20)

        XCTAssertEqual(plan.baseZoom, 20)
    }
}
