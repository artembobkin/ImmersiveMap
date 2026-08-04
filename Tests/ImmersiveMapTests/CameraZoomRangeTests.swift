// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The zoom range is a single funnel: every gesture, command and camera flight
/// ends up in `CameraStateController`, so clamping there is what actually keeps
/// the camera inside `minimumZoom ... maximumZoom`.
final class CameraZoomRangeTests: XCTestCase {
    private func cameraSettings(minimumZoom: Double,
                                maximumZoom: Double = 20) -> ImmersiveMapSettings.CameraSettings {
        var camera = ImmersiveMapSettings.default.camera
        camera.minimumZoom = minimumZoom
        camera.maximumZoom = maximumZoom
        return camera
    }

    private func position(zoom: Double) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                   longitudeDegrees: 0,
                                   zoom: zoom,
                                   bearing: 0,
                                   pitch: 0)
    }

    // MARK: - Clamping rules

    func testDefaultSettingsKeepTheWholeGlobeReachable() {
        // The default range must stay open at the bottom: an app that never
        // touches minimumZoom keeps the globe overview it had before.
        let camera = ImmersiveMapSettings.default.camera
        XCTAssertEqual(camera.minimumZoom, 0)
        XCTAssertEqual(camera.clampZoom(0), 0)
    }

    func testClampPullsZoomUpToMinimum() {
        XCTAssertEqual(cameraSettings(minimumZoom: 3).clampZoom(1.2), 3)
    }

    func testClampPushesZoomDownToMaximum() {
        XCTAssertEqual(cameraSettings(minimumZoom: 3, maximumZoom: 18).clampZoom(25), 18)
    }

    func testZoomInsideRangeIsUntouched() {
        XCTAssertEqual(cameraSettings(minimumZoom: 3, maximumZoom: 18).clampZoom(7.5), 7.5)
    }

    func testNegativeMinimumBehavesLikeZero() {
        // Zoom 0 already shows the whole world, so a negative bound means nothing.
        XCTAssertEqual(cameraSettings(minimumZoom: -5).clampZoom(0), 0)
    }

    func testInvertedRangeCollapsesToMaximum() {
        // A misconfigured range must still produce a reachable zoom rather than
        // clamping to a lower bound above the upper one.
        XCTAssertEqual(cameraSettings(minimumZoom: 22, maximumZoom: 18).clampZoom(10), 18)
    }

    // MARK: - Camera state

    func testInitialCameraStateRespectsMinimumZoom() {
        // The default state starts at zoom 0; the bound must hold from the
        // first frame, not from the first gesture.
        let controller = CameraStateController(settings: cameraSettings(minimumZoom: 5))

        XCTAssertEqual(controller.zoom, 5)
    }

    func testZoomOutStopsAtMinimum() {
        let controller = CameraStateController(settings: cameraSettings(minimumZoom: 4))
        controller.setCameraPosition(position(zoom: 10))

        controller.zoom(delta: -100)

        XCTAssertEqual(controller.zoom, 4)
    }

    func testSetCameraPositionClampsToMinimum() {
        let controller = CameraStateController(settings: cameraSettings(minimumZoom: 4))

        controller.setCameraPosition(position(zoom: 0.5))

        XCTAssertEqual(controller.zoom, 4)
    }

    /// Camera flights arc out to an overview before diving in, and every flight
    /// frame lands here, so this is what keeps a long `fly(to:)` from dipping
    /// below the range mid-air.
    func testSetCameraStateClampsToMinimum() {
        let controller = CameraStateController(settings: cameraSettings(minimumZoom: 4))
        let state = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                            zoom: 0.7,
                                            bearing: 0,
                                            pitch: 0)

        controller.setCameraState(state)

        XCTAssertEqual(controller.zoom, 4)
    }

    func testApplyingSettingsPullsCurrentZoomIntoRange() {
        // Raising the minimum while the map is already zoomed out must move the
        // camera, not leave it stranded outside the new range.
        let controller = CameraStateController(settings: cameraSettings(minimumZoom: 0))
        controller.setCameraPosition(position(zoom: 1))

        controller.apply(settings: cameraSettings(minimumZoom: 6))

        XCTAssertEqual(controller.zoom, 6)
    }

    func testCameraStateFromPositionClampsToMinimum() {
        let state = ImmersiveMapCameraState(cameraPosition: position(zoom: 1),
                                            cameraSettings: cameraSettings(minimumZoom: 5))

        XCTAssertEqual(state.zoom, 5)
    }
}
