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

    /// У полюса окно перехода растянуто на log2(1/cos(широты)) уровней: на зуме,
    /// где экватор уже плоский, высокие широты ещё в середине морфа.
    func testTransitionWindowIsStretchedNearPole() {
        let resolver = MapPresentationStateController(settings: .default)
        let polarCenter = ImmersiveMapProjection.worldMercator(latitude: 83.0 * .pi / 180.0,
                                                              longitude: 0)
        let midTransitionState = ImmersiveMapCameraState(centerWorldMercator: polarCenter,
                                                         zoom: 7.0,
                                                         bearing: 0,
                                                         pitch: 0)

        let midTransition = resolver.resolve(cameraState: midTransitionState)

        // cos(83°) ≈ 0.122: окно ≈ 1 + 3.04 уровня, на z7 пройдена лишь четверть.
        XCTAssertEqual(midTransition.renderSurfaceMode, .spherical)
        XCTAssertGreaterThan(midTransition.transition, 0.0)
        XCTAssertLessThan(midTransition.transition, 0.5)

        let deepZoomState = ImmersiveMapCameraState(centerWorldMercator: polarCenter,
                                                    zoom: 10.5,
                                                    bearing: 0,
                                                    pitch: 0)
        let completedTransition = resolver.resolve(cameraState: deepZoomState)

        XCTAssertEqual(completedTransition.renderSurfaceMode, .flat)
        XCTAssertEqual(completedTransition.transition, 1.0)
    }

    func testTransitionGrowsMonotonicallyWithZoomNearPole() {
        let resolver = MapPresentationStateController(settings: .default)
        let polarCenter = ImmersiveMapProjection.worldMercator(latitude: 83.0 * .pi / 180.0,
                                                              longitude: 0)
        let transitions = [6.5, 7.5, 8.5, 9.5].map { zoom in
            resolver.resolve(cameraState: ImmersiveMapCameraState(centerWorldMercator: polarCenter,
                                                                  zoom: zoom,
                                                                  bearing: 0,
                                                                  pitch: 0)).transition
        }

        XCTAssertEqual(transitions, transitions.sorted())
        XCTAssertEqual(Set(transitions).count, transitions.count, "Ступени перехода не должны слипаться")
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
