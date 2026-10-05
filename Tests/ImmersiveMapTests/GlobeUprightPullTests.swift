// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class GlobeUprightPullTests: XCTestCase {
    private typealias Settings = ImmersiveMapSettings.CameraSettings.GlobeUprightPull

    private let constraints = CameraConstraints(bearing: CameraBearingConstraint(maximumAbsoluteBearing: nil),
                                                pitch: CameraPitchConstraint(minimumPitch: 0, maximumPitch: 1.2))

    func testThePullIsOnByDefault() {
        XCTAssertEqual(ImmersiveMapSettings.default.camera.globeUprightPull, Settings())
    }

    func testWindowIsUprightAtTheLowerBoundAndBelowIt() {
        XCTAssertEqual(window(at: 3), GlobeUprightWindow(maximumAbsoluteBearing: 0, maximumPitch: 0))
        XCTAssertEqual(window(at: 0), GlobeUprightWindow(maximumAbsoluteBearing: 0, maximumPitch: 0))
    }

    func testWindowOpensLinearlyAcrossTheZoomRange() throws {
        let window = try XCTUnwrap(window(at: 4.5))

        XCTAssertEqual(window.maximumAbsoluteBearing, .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(window.maximumPitch, 0.6, accuracy: 0.0001)
    }

    func testNothingIsHeldFromTheUpperBoundOnOnTheFlatMapOrWithThePullOff() {
        XCTAssertNil(window(at: 6))
        XCTAssertNil(window(at: 12))
        XCTAssertNil(window(at: 2, renderSurfaceMode: .flat))
        XCTAssertNil(window(at: 2, settings: nil))
    }

    func testWindowClosesOntoThePitchFloorAndOpensToTheBearingCap() throws {
        let constraints = CameraConstraints(bearing: CameraBearingConstraint(maximumAbsoluteBearing: 1),
                                            pitch: CameraPitchConstraint(minimumPitch: 0.2, maximumPitch: 1.2))

        let closed = try XCTUnwrap(window(at: 3, constraints: constraints))
        XCTAssertEqual(closed.maximumPitch, 0.2, accuracy: 0.0001)

        let halfOpen = try XCTUnwrap(window(at: 4.5, constraints: constraints))
        XCTAssertEqual(halfOpen.maximumAbsoluteBearing, 0.5, accuracy: 0.0001)
        XCTAssertEqual(halfOpen.maximumPitch, 0.7, accuracy: 0.0001)
    }

    func testAnEmptyZoomRangeSwitchesAtItsZoom() {
        let settings = Settings(zoomRange: 4...4)

        XCTAssertEqual(window(at: 3.9, settings: settings),
                       GlobeUprightWindow(maximumAbsoluteBearing: 0, maximumPitch: 0))
        XCTAssertNil(window(at: 4, settings: settings))
    }

    func testAnglesInsideTheWindowAreLeftAsTheyCame() {
        let step = GlobeUprightPull.step(bearing: -0.3,
                                         pitch: 0.4,
                                         window: GlobeUprightWindow(maximumAbsoluteBearing: 0.5, maximumPitch: 0.6),
                                         deltaTime: 0.016,
                                         halfLife: 0.2)

        XCTAssertEqual(step, GlobeUprightPull.Step(bearing: -0.3, pitch: 0.4, isPulling: false))
    }

    func testTheExcessHalvesEveryHalfLife() {
        let step = GlobeUprightPull.step(bearing: -1.5,
                                         pitch: 1.0,
                                         window: GlobeUprightWindow(maximumAbsoluteBearing: 0.5, maximumPitch: 0.6),
                                         deltaTime: 0.2,
                                         halfLife: 0.2)

        XCTAssertEqual(step.bearing, -1.0, accuracy: 0.0001)
        XCTAssertEqual(step.pitch, 0.8, accuracy: 0.0001)
        XCTAssertTrue(step.isPulling)
    }

    func testTheFirstFrameMovesNothingAndKeepsPulling() {
        let step = GlobeUprightPull.step(bearing: 1,
                                         pitch: 0.5,
                                         window: GlobeUprightWindow(maximumAbsoluteBearing: 0, maximumPitch: 0),
                                         deltaTime: 0,
                                         halfLife: 0.2)

        XCTAssertEqual(step, GlobeUprightPull.Step(bearing: 1, pitch: 0.5, isPulling: true))
    }

    func testAnAngleCloseToTheWindowLandsOnIt() {
        let step = GlobeUprightPull.step(bearing: 0.0002,
                                         pitch: 0.0001,
                                         window: GlobeUprightWindow(maximumAbsoluteBearing: 0, maximumPitch: 0),
                                         deltaTime: 0.016,
                                         halfLife: 0.2)

        XCTAssertEqual(step, GlobeUprightPull.Step(bearing: 0, pitch: 0, isPulling: false))
    }

    func testAZeroHalfLifeStraightensAtOnce() {
        let step = GlobeUprightPull.step(bearing: 2,
                                         pitch: 1,
                                         window: GlobeUprightWindow(maximumAbsoluteBearing: 0.5, maximumPitch: 0.25),
                                         deltaTime: 0,
                                         halfLife: 0)

        XCTAssertEqual(step, GlobeUprightPull.Step(bearing: 0.5, pitch: 0.25, isPulling: false))
    }

    private func window(at zoom: Double,
                        settings: Settings? = Settings(),
                        renderSurfaceMode: ViewMode = .spherical,
                        constraints: CameraConstraints? = nil) -> GlobeUprightWindow? {
        GlobeUprightPull.window(zoom: zoom,
                                settings: settings,
                                renderSurfaceMode: renderSurfaceMode,
                                constraints: constraints ?? self.constraints)
    }
}
