// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CameraConstraintResolverTests: XCTestCase {
    private let settings = ImmersiveMapSettings.default.camera

    func testFlatPitchLimitIsAlwaysEightyFiveDegrees() {
        XCTAssertEqual(flatMaximumPitch(at: 0), degrees(85), accuracy: 0.0001)
        XCTAssertEqual(flatMaximumPitch(at: 12), degrees(85), accuracy: 0.0001)
        XCTAssertEqual(flatMaximumPitch(at: 20), degrees(85), accuracy: 0.0001)
    }

    /// The globe's ceiling no longer eases in with zoom: it is the flat
    /// map's fixed 85 degrees at every zoom, the whole planet included.
    func testGlobePitchLimitIsAlwaysEightyFiveDegrees() {
        XCTAssertEqual(globeMaximumPitch(at: 0), degrees(85), accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 1.5), degrees(85), accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 3), degrees(85), accuracy: 0.0001)
        XCTAssertEqual(globeMaximumPitch(at: 20), degrees(85), accuracy: 0.0001)
    }

    func testDefaultsLeavePitchFloorBearingCapAndBoundsOff() {
        // Every camera limit is opt-in: a reachable top-down view, unbounded
        // rotation on both surfaces at every zoom, and the whole world open.
        XCTAssertEqual(settings.minimumPitch, 0)
        XCTAssertNil(settings.maximumAbsoluteBearing)
        XCTAssertNil(settings.globeBearingLimit)
        XCTAssertNil(settings.bounds)
        XCTAssertNil(resolve(.flat).bearing.maximumAbsoluteBearing)
        XCTAssertNil(resolve(.spherical, at: 0).bearing.maximumAbsoluteBearing)
    }

    func testGlobeBearingCapWithoutAWindowAppliesAtEveryZoom() {
        var settings = settings
        settings.maximumAbsoluteBearing = .pi / 2

        XCTAssertEqual(globeMaximumBearing(at: 0, settings: settings), .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(globeMaximumBearing(at: 20, settings: settings), .pi / 2, accuracy: 0.0001)
    }

    func testFlatPitchFloorHoldsAtEveryZoom() {
        var settings = settings
        settings.minimumPitch = 0.35

        XCTAssertEqual(resolve(.flat, at: 0, settings: settings).pitch.apply(to: 0), 0.35, accuracy: 0.0001)
        XCTAssertEqual(resolve(.flat, at: 20, settings: settings).pitch.apply(to: 0), 0.35, accuracy: 0.0001)
    }

    /// The globe's ceiling is the flat map's at every zoom, so a floor under
    /// it holds on the sphere exactly as it does on the plane.
    func testGlobePitchFloorHoldsAtEveryZoom() {
        var settings = settings
        settings.minimumPitch = 0.35

        XCTAssertEqual(resolve(.spherical, at: 0, settings: settings).pitch.apply(to: 0), 0.35, accuracy: 0.0001)
        XCTAssertEqual(resolve(.spherical, at: 0, settings: settings).pitch.apply(to: 0.9), 0.9, accuracy: 0.0001)
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
        // Window floor 15 degrees, unlocked at zoom 6. The cap replaces the
        // half turn as the widest the window opens.
        var settings = settings
        settings.maximumAbsoluteBearing = .pi / 2
        settings.globeBearingLimit = .init(minimumAbsoluteBearing: .pi / 12, unlockZoom: 6)

        let floor = Float.pi / 12
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
        settings.globeBearingLimit = .init(minimumAbsoluteBearing: .pi / 12, unlockZoom: 6)

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
            XCTFail("A capped globe bearing is never unbounded.")
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
