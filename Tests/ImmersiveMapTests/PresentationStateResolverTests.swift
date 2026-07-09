// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PresentationStateResolverTests: XCTestCase {
    func testAutomaticPresentationUsesSphericalSurfaceAtLowZoom() {
        let resolver = MapPresentationStateController(settings: .default)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: 5.0,
                                                  bearing: 0,
                                                  pitch: 0)

        let resolvedPresentation = resolver.resolve(cameraState: cameraState)

        XCTAssertEqual(resolvedPresentation.renderSurfaceMode, .spherical)
        XCTAssertEqual(resolvedPresentation.screenSpaceProjectionMode, .globe)
        XCTAssertEqual(resolvedPresentation.transition, 0.0)
    }

    func testAutomaticPresentationUsesFlatSurfaceAtHighZoom() {
        let resolver = MapPresentationStateController(settings: .default)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: 7.0,
                                                  bearing: 0,
                                                  pitch: 0)

        let resolvedPresentation = resolver.resolve(cameraState: cameraState)

        XCTAssertEqual(resolvedPresentation.renderSurfaceMode, .flat)
        XCTAssertEqual(resolvedPresentation.screenSpaceProjectionMode, .flat)
        XCTAssertEqual(resolvedPresentation.transition, 1.0)
    }

    func testSwitchRenderSurfaceModeTemporarilyForcesOppositeSurfaceAndSecondSwitchReturnsToAutomatic() {
        let resolver = MapPresentationStateController(settings: .default)
        let highZoomCameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                          zoom: 7.0,
                                                          bearing: 0,
                                                          pitch: 0)

        resolver.switchRenderSurfaceMode(cameraState: highZoomCameraState)
        let forcedPresentation = resolver.resolve(cameraState: highZoomCameraState)

        XCTAssertEqual(forcedPresentation.renderSurfaceMode, .spherical)
        XCTAssertEqual(forcedPresentation.transition, 0.0)

        resolver.switchRenderSurfaceMode(cameraState: highZoomCameraState)
        let automaticPresentation = resolver.resolve(cameraState: highZoomCameraState)

        XCTAssertEqual(automaticPresentation.renderSurfaceMode, .flat)
        XCTAssertEqual(automaticPresentation.transition, 1.0)
    }
}
