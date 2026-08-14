// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The corner control zones capture drags that would otherwise pan the map, and
/// nothing on screen announces them, so they are opt-in. These tests guard the
/// settings that gate them: the runtime creates the zones straight from here.
@MainActor
final class CameraControlZoneSettingsTests: XCTestCase {
    func testControlZonesAreOffByDefault() {
        let controlZones = ImmersiveMapSettings.default.camera.controlZones

        XCTAssertFalse(controlZones.isPitchZoneEnabled)
        XCTAssertFalse(controlZones.isZoomZoneEnabled)
    }

    func testModifierEnablesBothZones() {
        let controlZones = ImmersiveMapView().cameraControlZones().settings.camera.controlZones

        XCTAssertTrue(controlZones.isPitchZoneEnabled)
        XCTAssertTrue(controlZones.isZoomZoneEnabled)
    }

    func testModifierCanEnableASingleZone() {
        let controlZones = ImmersiveMapView().cameraControlZones(pitch: false).settings.camera.controlZones

        XCTAssertFalse(controlZones.isPitchZoneEnabled)
        XCTAssertTrue(controlZones.isZoomZoneEnabled)
    }

    func testZoomRangeModifierLeavesTheOmittedBoundAlone() {
        let camera = ImmersiveMapView()
            .zoomRange(minimum: 3)
            .settings
            .camera

        XCTAssertEqual(camera.minimumZoom, 3)
        XCTAssertEqual(camera.maximumZoom, ImmersiveMapSettings.default.camera.maximumZoom)
    }

    func testPitchRangeModifierLeavesTheOmittedBoundAlone() {
        let camera = ImmersiveMapView()
            .pitchRange(minimum: 0.2)
            .settings
            .camera

        XCTAssertEqual(camera.minimumPitch, 0.2)
        XCTAssertEqual(camera.maximumPitch, ImmersiveMapSettings.default.camera.maximumPitch)
    }

    func testBearingLimitModifierSetsAndClearsTheCap() {
        let capped = ImmersiveMapView().bearingLimit(.pi / 2).settings.camera
        XCTAssertEqual(capped.maximumAbsoluteBearing, .pi / 2)

        let cleared = ImmersiveMapView().bearingLimit(.pi / 2).bearingLimit(nil).settings.camera
        XCTAssertNil(cleared.maximumAbsoluteBearing)
    }

    func testCameraModifiersDoNotOverwriteEachOther() {
        // All of these rewrite CameraSettings, so a later one must not silently
        // undo an earlier one.
        let camera = ImmersiveMapView()
            .cameraControlZones(pitch: false)
            .zoomRange(minimum: 4, maximum: 17)
            .pitchRange(minimum: 0.1, maximum: 1.2)
            .bearingLimit(.pi / 3)
            .settings
            .camera

        XCTAssertEqual(camera.minimumZoom, 4)
        XCTAssertEqual(camera.maximumZoom, 17)
        XCTAssertEqual(camera.minimumPitch, 0.1)
        XCTAssertEqual(camera.maximumPitch, 1.2)
        XCTAssertEqual(camera.maximumAbsoluteBearing, .pi / 3)
        XCTAssertTrue(camera.controlZones.isZoomZoneEnabled)
        XCTAssertFalse(camera.controlZones.isPitchZoneEnabled)
    }
}
