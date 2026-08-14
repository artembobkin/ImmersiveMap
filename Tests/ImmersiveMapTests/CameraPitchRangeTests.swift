// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The pitch range is the same funnel as the zoom range: every gesture, command
/// and flight frame lands in `CameraStateController`, so clamping there is what
/// actually keeps the camera between `minimumPitch` and `maximumPitch`.
final class CameraPitchRangeTests: XCTestCase {
    private func cameraSettings(minimumPitch: Float,
                                maximumPitch: Float = ImmersiveMapSettings.default.camera.maximumPitch) -> ImmersiveMapSettings.CameraSettings {
        var camera = ImmersiveMapSettings.default.camera
        camera.minimumPitch = minimumPitch
        camera.maximumPitch = maximumPitch
        return camera
    }

    private func position(pitch: Float, zoom: Double = 10) -> ImmersiveMapCameraPosition {
        ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                   longitudeDegrees: 0,
                                   zoom: zoom,
                                   bearing: 0,
                                   pitch: pitch)
    }

    // MARK: - Clamping rules

    func testDefaultSettingsKeepTheTopDownViewReachable() {
        // The default range must stay open at the bottom: an app that never
        // touches minimumPitch keeps the straight-down view it had before.
        let camera = ImmersiveMapSettings.default.camera
        XCTAssertEqual(camera.minimumPitch, 0)
        XCTAssertEqual(camera.clampPitch(0, at: 10), 0)
    }

    func testClampPullsPitchUpToTheFloor() {
        XCTAssertEqual(cameraSettings(minimumPitch: 0.4).clampPitch(0.1, at: 10), 0.4, accuracy: 0.0001)
    }

    func testClampPushesPitchDownToTheCeiling() {
        XCTAssertEqual(cameraSettings(minimumPitch: 0.4, maximumPitch: 1.0).clampPitch(1.5, at: 10), 1.0, accuracy: 0.0001)
    }

    func testPitchInsideRangeIsUntouched() {
        XCTAssertEqual(cameraSettings(minimumPitch: 0.4, maximumPitch: 1.0).clampPitch(0.7, at: 10), 0.7, accuracy: 0.0001)
    }

    func testNegativeFloorBehavesLikeZero() {
        XCTAssertEqual(cameraSettings(minimumPitch: -1).clampPitch(-0.5, at: 10), 0)
    }

    func testFloorAboveCeilingCollapsesToCeiling() {
        // A misconfigured range must still produce a reachable pitch rather
        // than clamping to a floor above the ceiling.
        XCTAssertEqual(cameraSettings(minimumPitch: 2.0, maximumPitch: 1.0).clampPitch(0.2, at: 10), 1.0, accuracy: 0.0001)
    }

    // MARK: - Camera state funnel

    func testInitialCameraStateRespectsTheFloor() {
        // The default state starts at pitch 0; the floor must hold from the
        // first frame, not from the first gesture.
        let controller = CameraStateController(settings: cameraSettings(minimumPitch: 0.4))

        XCTAssertEqual(controller.pitch, 0.4, accuracy: 0.0001)
    }

    func testSetPitchStopsAtTheFloor() {
        let controller = CameraStateController(settings: cameraSettings(minimumPitch: 0.4))
        controller.setCameraPosition(position(pitch: 0.8))

        controller.setPitch(0)

        XCTAssertEqual(controller.pitch, 0.4, accuracy: 0.0001)
    }

    func testSetCameraPositionClampsPitchToTheFloor() {
        let controller = CameraStateController(settings: cameraSettings(minimumPitch: 0.4))

        controller.setCameraPosition(position(pitch: 0.1))

        XCTAssertEqual(controller.pitch, 0.4, accuracy: 0.0001)
    }

    /// Camera flights interpolate a raw state per frame and every one of those
    /// frames lands here, so this is what keeps a `fly(to:)` from dipping below
    /// the floor mid-air.
    func testSetCameraStateClampsPitchToTheFloor() {
        let controller = CameraStateController(settings: cameraSettings(minimumPitch: 0.4))
        let state = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                            zoom: 10,
                                            bearing: 0,
                                            pitch: 0.05)

        controller.setCameraState(state)

        XCTAssertEqual(controller.pitch, 0.4, accuracy: 0.0001)
    }

    func testApplyingSettingsPullsCurrentPitchUpToTheFloor() {
        // Raising the floor while the map is already level must move the
        // camera, not leave it stranded outside the new range.
        let controller = CameraStateController(settings: cameraSettings(minimumPitch: 0))
        controller.setCameraPosition(position(pitch: 0.1))

        controller.apply(settings: cameraSettings(minimumPitch: 0.5))

        XCTAssertEqual(controller.pitch, 0.5, accuracy: 0.0001)
    }

    func testCameraStateFromPositionClampsPitchToTheFloor() {
        let state = ImmersiveMapCameraState(cameraPosition: position(pitch: 0.1),
                                            cameraSettings: cameraSettings(minimumPitch: 0.4))

        XCTAssertEqual(state.pitch, 0.4, accuracy: 0.0001)
    }

    // MARK: - Floor versus the globe ceiling

    /// The settings-level floor is surface-blind; on the globe the constraint's
    /// zoom-eased ceiling can sit below it. The anchored-zoom compensation runs
    /// after the constraint clamp and must move only the center: pushing the
    /// whole state back through `setCameraState` would re-apply the floor and
    /// leave the camera resting above the ceiling.
    func testCenterShiftAfterGlobeConstraintDoesNotRefloorPitch() {
        let settings = cameraSettings(minimumPitch: 0.6)
        let controller = CameraStateController(settings: settings)
        controller.setCameraPosition(position(pitch: 0.9, zoom: 1))

        let constraints = CameraConstraintResolver.resolve(cameraState: controller.currentCameraState(),
                                                           cameraSettings: settings,
                                                           renderSurfaceMode: .spherical)
        controller.clampPitch(to: constraints.pitch)
        let ceiling = constraints.pitch.clampedMaximumPitch
        XCTAssertLessThan(ceiling, 0.6, "The scenario needs the globe ceiling below the floor.")
        XCTAssertEqual(controller.pitch, ceiling, accuracy: 0.0001)

        controller.setCenterWorldMercator(SIMD2<Double>(0.52, 0.48))

        XCTAssertEqual(controller.pitch, ceiling, accuracy: 0.0001)
    }

    /// The still recorder's default (no camera position) is the controller's
    /// initial state, which the floor lifts to a tilt; at zoom 0 the globe's
    /// ceiling is 0, so applying the surface constraints must level it off,
    /// which is why the recorder applies them even with no position given.
    func testZoomedOutGlobeConstraintLevelsTheFlooredDefaultState() {
        let settings = cameraSettings(minimumPitch: 0.35)
        let controller = CameraStateController(settings: settings)
        XCTAssertEqual(controller.pitch, 0.35, accuracy: 0.0001)

        let constraints = CameraConstraintResolver.resolve(cameraState: controller.currentCameraState(),
                                                           cameraSettings: settings,
                                                           renderSurfaceMode: .spherical)
        controller.clampPitch(to: constraints.pitch)

        XCTAssertEqual(controller.pitch, 0, accuracy: 0.0001)
    }
}
