// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

@MainActor
final class TourVideoTimelineDriverTests: XCTestCase {
    private let start = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                   longitudeDegrees: 0,
                                                   zoom: 10,
                                                   bearing: 0,
                                                   pitch: 0)

    private func makeShot(latitude: Double,
                          longitude: Double,
                          zoom: Double = 10,
                          bearing: Float = 0,
                          pitch: Float = 0,
                          duration: TimeInterval,
                          routeStyle: CameraFlightRouteStyle = .mercatorShortestPath,
                          holdAfter: TimeInterval = 0) -> ImmersiveMapCameraTourShot {
        ImmersiveMapCameraTourShot(position: ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                                        longitudeDegrees: longitude,
                                                                        zoom: zoom,
                                                                        bearing: bearing,
                                                                        pitch: pitch),
                                   options: CameraFlightOptions(duration: duration,
                                                                routeStyle: routeStyle,
                                                                altitudeStyle: .direct),
                                   holdAfter: holdAfter)
    }

    private func makeDriver(shots: [ImmersiveMapCameraTourShot],
                            initialPosition: ImmersiveMapCameraPosition,
                            settings: ImmersiveMapSettings = .default)
        -> (TourVideoTimelineDriver, FrameCameraStateResolver) {
        let renderCamera = FrameCameraStateResolver(settings: settings)
        let presentation = MapPresentationStateController(settings: settings)
        let driver = TourVideoTimelineDriver(shots: shots,
                                             initialPosition: initialPosition,
                                             settings: settings,
                                             renderCamera: renderCamera,
                                             presentationStateResolver: presentation)
        return (driver, renderCamera)
    }

    // MARK: - Plan

    func testPlanSumsFlightDurationsAndHolds() {
        let shots = [
            makeShot(latitude: 10, longitude: 10, duration: 2.0, holdAfter: 0.5),
            makeShot(latitude: 20, longitude: 20, duration: 1.0)
        ]

        let plan = TourVideoTimelineDriver.makePlan(shots: shots,
                                                    initialPosition: start,
                                                    settings: .default,
                                                    framesPerSecond: 60)

        XCTAssertEqual(plan.totalDuration, 3.5, accuracy: 1e-9)
        XCTAssertEqual(plan.frameCount, 211)
    }

    func testPlanCollapsesDegenerateShotToHoldOnly() {
        // Flying to the position the tour already stands on: the live
        // controller completes immediately; the plan must charge only the hold.
        let shots = [
            makeShot(latitude: start.latitudeDegrees,
                     longitude: start.longitudeDegrees,
                     duration: 3.0,
                     holdAfter: 0.5)
        ]

        let plan = TourVideoTimelineDriver.makePlan(shots: shots,
                                                    initialPosition: start,
                                                    settings: .default,
                                                    framesPerSecond: 60)

        XCTAssertEqual(plan.totalDuration, 0.5, accuracy: 1e-9)
    }

    func testPlanForEmptyShotsIsSingleFrame() {
        let plan = TourVideoTimelineDriver.makePlan(shots: [],
                                                    initialPosition: start,
                                                    settings: .default,
                                                    framesPerSecond: 60)

        XCTAssertEqual(plan.totalDuration, 0)
        XCTAssertEqual(plan.frameCount, 1)
    }

    // MARK: - Driving

    func testInitJumpsToInitialPosition() {
        let establish = ImmersiveMapCameraPosition(latitudeDegrees: 35.68,
                                                   longitudeDegrees: 139.76,
                                                   zoom: 6,
                                                   bearing: 0.2,
                                                   pitch: 0.1)

        let (_, renderCamera) = makeDriver(shots: [makeShot(latitude: 10, longitude: 10, duration: 1)],
                                           initialPosition: establish)

        let position = renderCamera.currentCameraPosition()
        XCTAssertEqual(position.latitudeDegrees, establish.latitudeDegrees, accuracy: 1e-6)
        XCTAssertEqual(position.longitudeDegrees, establish.longitudeDegrees, accuracy: 1e-6)
        XCTAssertEqual(position.zoom, establish.zoom, accuracy: 1e-9)
    }

    func testFlightEndsSnappedOnExactTarget() {
        let target = makeShot(latitude: 25.2, longitude: 55.27, zoom: 12, bearing: 0.3, pitch: 0.4, duration: 1.0)
        let (driver, renderCamera) = makeDriver(shots: [target], initialPosition: start)

        driver.advance(to: 0)
        driver.advance(to: 0.5)
        let midFlight = renderCamera.currentCameraPosition()
        XCTAssertNotEqual(midFlight.latitudeDegrees, target.position.latitudeDegrees, accuracy: 1e-9)

        driver.advance(to: 2.0)

        let position = renderCamera.currentCameraPosition()
        XCTAssertEqual(position.latitudeDegrees, target.position.latitudeDegrees, accuracy: 1e-9)
        XCTAssertEqual(position.longitudeDegrees, target.position.longitudeDegrees, accuracy: 1e-9)
        XCTAssertEqual(position.zoom, target.position.zoom, accuracy: 1e-9)
        XCTAssertEqual(position.bearing, target.position.bearing, accuracy: 1e-6)
        XCTAssertTrue(driver.isFinished)
    }

    func testFrameStepJumpingPastShortSegmentsStillLandsOnLastTarget() {
        // Segments far shorter than one frame step: advancing straight past
        // them must land each one on its exact target.
        let shots = [
            makeShot(latitude: 5, longitude: 5, duration: 0.001),
            makeShot(latitude: 6, longitude: 6, duration: 0.001),
            makeShot(latitude: 7, longitude: 7, duration: 0.001)
        ]
        let (driver, renderCamera) = makeDriver(shots: shots, initialPosition: start)

        driver.advance(to: 1.0)

        let position = renderCamera.currentCameraPosition()
        XCTAssertEqual(position.latitudeDegrees, 7, accuracy: 1e-9)
        XCTAssertEqual(position.longitudeDegrees, 7, accuracy: 1e-9)
        XCTAssertTrue(driver.isFinished)
    }

    func testHoldKeepsCameraParkedOnTarget() {
        let shots = [makeShot(latitude: 10, longitude: 10, duration: 1.0, holdAfter: 1.0)]
        let (driver, renderCamera) = makeDriver(shots: shots, initialPosition: start)

        driver.advance(to: 1.5)

        let position = renderCamera.currentCameraPosition()
        XCTAssertEqual(position.latitudeDegrees, 10, accuracy: 1e-9)
        XCTAssertFalse(driver.isFinished)

        driver.advance(to: 2.5)
        XCTAssertTrue(driver.isFinished)
    }

    // MARK: - Route resolution

    func testAutomaticRouteMatchesMercatorAtHighZoom() {
        // Both endpoints far above the globe-transition zoom: `.automatic`
        // must fly the mercator shortest path.
        let automaticShot = makeShot(latitude: 25.2, longitude: 55.27, zoom: 16,
                                     duration: 1.0, routeStyle: .automatic)
        let mercatorShot = makeShot(latitude: 25.2, longitude: 55.27, zoom: 16,
                                    duration: 1.0, routeStyle: .mercatorShortestPath)
        let greatCircleShot = makeShot(latitude: 25.2, longitude: 55.27, zoom: 16,
                                       duration: 1.0, routeStyle: .greatCircle)
        let highZoomStart = ImmersiveMapCameraPosition(latitudeDegrees: 35.68,
                                                       longitudeDegrees: 139.76,
                                                       zoom: 16,
                                                       bearing: 0,
                                                       pitch: 0)

        let (automaticDriver, automaticCamera) = makeDriver(shots: [automaticShot], initialPosition: highZoomStart)
        let (mercatorDriver, mercatorCamera) = makeDriver(shots: [mercatorShot], initialPosition: highZoomStart)
        let (greatCircleDriver, greatCircleCamera) = makeDriver(shots: [greatCircleShot], initialPosition: highZoomStart)
        automaticDriver.advance(to: 0.5)
        mercatorDriver.advance(to: 0.5)
        greatCircleDriver.advance(to: 0.5)

        let automaticPosition = automaticCamera.currentCameraPosition()
        let mercatorPosition = mercatorCamera.currentCameraPosition()
        let greatCirclePosition = greatCircleCamera.currentCameraPosition()
        XCTAssertEqual(automaticPosition.latitudeDegrees, mercatorPosition.latitudeDegrees, accuracy: 1e-9)
        XCTAssertEqual(automaticPosition.longitudeDegrees, mercatorPosition.longitudeDegrees, accuracy: 1e-9)
        XCTAssertNotEqual(automaticPosition.latitudeDegrees, greatCirclePosition.latitudeDegrees, accuracy: 1e-6)
    }

    func testAutomaticRouteMatchesGreatCircleAtLowZoom() {
        let automaticShot = makeShot(latitude: 25.2, longitude: 55.27, zoom: 1.5,
                                     duration: 1.0, routeStyle: .automatic)
        let greatCircleShot = makeShot(latitude: 25.2, longitude: 55.27, zoom: 1.5,
                                       duration: 1.0, routeStyle: .greatCircle)
        let lowZoomStart = ImmersiveMapCameraPosition(latitudeDegrees: 35.68,
                                                      longitudeDegrees: 139.76,
                                                      zoom: 1.5,
                                                      bearing: 0,
                                                      pitch: 0)

        let (automaticDriver, automaticCamera) = makeDriver(shots: [automaticShot], initialPosition: lowZoomStart)
        let (greatCircleDriver, greatCircleCamera) = makeDriver(shots: [greatCircleShot], initialPosition: lowZoomStart)
        automaticDriver.advance(to: 0.5)
        greatCircleDriver.advance(to: 0.5)

        let automaticPosition = automaticCamera.currentCameraPosition()
        let greatCirclePosition = greatCircleCamera.currentCameraPosition()
        XCTAssertEqual(automaticPosition.latitudeDegrees, greatCirclePosition.latitudeDegrees, accuracy: 1e-9)
        XCTAssertEqual(automaticPosition.longitudeDegrees, greatCirclePosition.longitudeDegrees, accuracy: 1e-9)
    }

    // MARK: - Constraints

    func testAppliedStatesRespectPitchConstraints() {
        let maximumPitch = ImmersiveMapSettings.default.camera.maximumPitch
        let shots = [makeShot(latitude: 10, longitude: 10, zoom: 16, pitch: 3.0, duration: 1.0)]
        let (driver, renderCamera) = makeDriver(shots: shots, initialPosition: start)

        var observedMaximumPitch: Float = 0
        for step in 0...60 {
            driver.advance(to: TimeInterval(step) / 60.0 * 2.0)
            observedMaximumPitch = max(observedMaximumPitch, renderCamera.currentCameraPosition().pitch)
        }

        XCTAssertLessThanOrEqual(observedMaximumPitch, maximumPitch + 1e-6)
    }

    func testEmptyShotsFinishImmediately() {
        let (driver, renderCamera) = makeDriver(shots: [], initialPosition: start)

        XCTAssertTrue(driver.isFinished)
        driver.advance(to: 1.0)
        let position = renderCamera.currentCameraPosition()
        XCTAssertEqual(position.latitudeDegrees, start.latitudeDegrees, accuracy: 1e-9)
    }
}
