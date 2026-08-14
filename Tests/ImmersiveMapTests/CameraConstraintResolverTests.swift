// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CameraConstraintResolverTests: XCTestCase {
    private let settings = ImmersiveMapSettings.default.camera

    func testFlatPitchLimitIsAlwaysSeventyFiveDegrees() {
        XCTAssertEqual(flatMaximumPitch(at: 0), degrees(75), accuracy: 0.0001)
        XCTAssertEqual(flatMaximumPitch(at: 12), degrees(75), accuracy: 0.0001)
        XCTAssertEqual(flatMaximumPitch(at: 20), degrees(75), accuracy: 0.0001)
    }

    func testGlobePitchLimitUnlocksLinearlyUntilZoomThree() {
        XCTAssertEqual(globeMaximumPitch(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 1.5), degrees(37.5), accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 3), degrees(75), accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 20), degrees(75), accuracy: 0.0001)
    }

    func testDefaultsLeavePitchFloorAndBearingCapOff() {
        // The defaults must preserve the behavior apps already have: a
        // reachable top-down view and unbounded rotation on the flat map.
        XCTAssertEqual(settings.minimumPitch, 0)
        XCTAssertNil(settings.maximumAbsoluteBearing)
        XCTAssertNil(resolve(.flat).bearing.maximumAbsoluteBearing)
    }

    func testFlatPitchFloorHoldsAtEveryZoom() {
        var settings = settings
        settings.minimumPitch = 0.35

        XCTAssertEqual(resolve(.flat, at: 0, settings: settings).pitch.apply(to: 0), 0.35, accuracy: 0.0001)
        XCTAssertEqual(resolve(.flat, at: 20, settings: settings).pitch.apply(to: 0), 0.35, accuracy: 0.0001)
    }

    func testGlobePitchFloorYieldsToTheZoomedOutCeiling() {
        // With the default unlock at zoom 3, the globe's ceiling at zoom 0 is
        // 0: the floor gives way instead of pinning a whole-globe view at a
        // tilt it is not allowed to have.
        var settings = settings
        settings.minimumPitch = 0.35

        XCTAssertEqual(resolve(.spherical, at: 0, settings: settings).pitch.apply(to: 0.9), 0, accuracy: 0.0001)
        XCTAssertEqual(resolve(.spherical, at: 3, settings: settings).pitch.apply(to: 0), 0.35, accuracy: 0.0001)
    }

    func testFlatBearingCapClampsRotation() {
        var settings = settings
        settings.maximumAbsoluteBearing = .pi / 2

        let bearing = resolve(.flat, settings: settings).bearing
        XCTAssertEqual(bearing.apply(to: 2.5), .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(bearing.apply(to: -2.5), -.pi / 2, accuracy: 0.0001)
    }

    func testGlobeBearingWindowOpensToTheCapInsteadOfTheHalfTurn() {
        // Defaults: window floor 15 degrees, unlocked at zoom 6. The cap
        // replaces the half turn as the widest the window opens.
        var settings = settings
        settings.maximumAbsoluteBearing = .pi / 2

        let floor = settings.globeMinimumAbsoluteBearing
        XCTAssertEqual(globeMaximumBearing(at: 0, settings: settings), floor, accuracy: 0.0001)
        XCTAssertEqual(globeMaximumBearing(at: 3, settings: settings),
                       floor + (Float.pi / 2 - floor) * 0.5,
                       accuracy: 0.0001)
        XCTAssertEqual(globeMaximumBearing(at: 6, settings: settings), .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(globeMaximumBearing(at: 20, settings: settings), .pi / 2, accuracy: 0.0001)
    }

    func testGlobeBearingCapBelowTheWindowFloorCollapsesTheWindow() {
        var settings = settings
        settings.maximumAbsoluteBearing = .pi / 24

        XCTAssertEqual(globeMaximumBearing(at: 0, settings: settings), .pi / 24, accuracy: 0.0001)
        XCTAssertEqual(globeMaximumBearing(at: 20, settings: settings), .pi / 24, accuracy: 0.0001)
    }

    private func flatMaximumPitch(at zoom: Double) -> Float {
        resolve(.flat, at: zoom).pitch.maximumPitch
    }

    private func globeMaximumPitch(at zoom: Double) -> Float {
        resolve(.spherical, at: zoom).pitch.maximumPitch
    }

    private func globeMaximumBearing(at zoom: Double,
                                     settings: ImmersiveMapSettings.CameraSettings) -> Float {
        guard let maximum = resolve(.spherical, at: zoom, settings: settings).bearing.maximumAbsoluteBearing else {
            XCTFail("The globe bearing window is never unbounded.")
            return .nan
        }
        return maximum
    }

    private func resolve(_ renderSurfaceMode: ViewMode,
                         at zoom: Double = 10,
                         settings: ImmersiveMapSettings.CameraSettings? = nil) -> CameraConstraints {
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: zoom,
                                                  bearing: 0,
                                                  pitch: 0)
        return CameraConstraintResolver.resolve(cameraState: cameraState,
                                                cameraSettings: settings ?? self.settings,
                                                renderSurfaceMode: renderSurfaceMode)
    }

    private func degrees(_ value: Float) -> Float {
        value * .pi / 180
    }
}
