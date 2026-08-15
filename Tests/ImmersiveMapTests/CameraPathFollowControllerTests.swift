// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

@testable import ImmersiveMap
import CoreGraphics
import Metal
import QuartzCore
import simd
import XCTest

/// A camera travelling along a path on a real host view, driven with injected
/// times: where it ends up, who wins when something else takes the camera, and
/// that the completion fires exactly once on every exit.
final class CameraPathFollowControllerTests: XCTestCase {
    private let overview = ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                      longitudeDegrees: 0,
                                                      zoom: 2.0)
    private let path = ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 0, longitude: 0),
                                           to: GeoCoordinate(latitude: 0, longitude: 40))

    // MARK: - Traversal

    @MainActor
    func testCameraTravelsFromTheFirstWaypointToTheLast() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var completed: Bool?
        // Zero smoothing pins the camera on the path point, which is what makes
        // the endpoint exact and the assertion meaningful.
        view.followForTesting(path: path,
                              duration: 10,
                              options: ImmersiveMapCameraFollowOptions(bearing: .unchanged,
                                                                       smoothingHalfLife: 0),
                              completion: { completed = $0 },
                              currentTime: 0)
        XCTAssertTrue(view.hasActiveCameraPathFollowForTesting)

        view.advanceCameraPathFollowForTesting(currentTime: 0)
        XCTAssertEqual(try longitude(of: camera), 0, accuracy: 1e-4)

        view.advanceCameraPathFollowForTesting(currentTime: 5)
        XCTAssertEqual(try longitude(of: camera), 20, accuracy: 1e-3)
        XCTAssertNil(completed)

        view.advanceCameraPathFollowForTesting(currentTime: 10)
        XCTAssertEqual(try longitude(of: camera), 40, accuracy: 1e-3)
        XCTAssertEqual(completed, true)
        XCTAssertFalse(view.hasActiveCameraPathFollowForTesting)
    }

    /// Zoom and pitch are left alone unless the options name them, so an app
    /// can keep zooming while the camera travels.
    @MainActor
    func testUnsetOptionsLeaveZoomAlone() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        view.followForTesting(path: path,
                              duration: 4,
                              options: ImmersiveMapCameraFollowOptions(bearing: .unchanged,
                                                                       smoothingHalfLife: 0),
                              currentTime: 0)
        view.advanceCameraPathFollowForTesting(currentTime: 2)

        XCTAssertEqual(try XCTUnwrap(camera.currentCameraPosition()).zoom, overview.zoom, accuracy: 1e-6)
    }

    @MainActor
    func testRequestedZoomIsReachedByTheEnd() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        view.followForTesting(path: path,
                              duration: 4,
                              options: ImmersiveMapCameraFollowOptions(zoom: 3.5,
                                                                       bearing: .unchanged,
                                                                       smoothingHalfLife: 0),
                              currentTime: 0)
        view.advanceCameraPathFollowForTesting(currentTime: 4)

        XCTAssertEqual(try XCTUnwrap(camera.currentCameraPosition()).zoom, 3.5, accuracy: 1e-6)
    }

    /// The smoothed camera trails the point instead of snapping onto it.
    @MainActor
    func testSmoothingMakesTheCameraTrailThePoint() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        view.followForTesting(path: path,
                              duration: 10,
                              options: ImmersiveMapCameraFollowOptions(bearing: .unchanged,
                                                                       smoothingHalfLife: 0.5),
                              currentTime: 0)
        var time: CFTimeInterval = 0
        while time < 5 {
            time += 1.0 / 60.0
            view.advanceCameraPathFollowForTesting(currentTime: time)
        }

        let trailing = try longitude(of: camera)
        XCTAssertGreaterThan(trailing, 0)
        XCTAssertLessThan(trailing, 20, "The smoothed camera must lag the point it chases")
    }

    // MARK: - Course

    /// The documented promise of `.course` is that the direction of travel
    /// points up the screen. Asserting the bearing value alone would just
    /// restate the implementation, so this projects a point further along the
    /// path and checks where it actually lands.
    ///
    /// Zoom 8 is past `globeBearingUnlockZoom`, so the globe bearing limit does
    /// not clamp the turn and the check is about the sign, not the constraint.
    @MainActor
    func testCourseModePutsTheDirectionOfTravelUpTheScreen() throws {
        try skipUnlessMetalAvailable()

        for (name, course) in [("east", 90.0), ("west", 270.0), ("north", 0.0), ("south", 180.0)] {
            let camera = ImmersiveMapCameraController()
            let view = makeHostView(camera: camera, zoom: 8)
            let coursePath = try XCTUnwrap(Self.path(course: course))

            view.followForTesting(path: coursePath,
                                  duration: 10,
                                  options: ImmersiveMapCameraFollowOptions(bearing: .course,
                                                                           smoothingHalfLife: 0),
                                  currentTime: 0)
            view.advanceCameraPathFollowForTesting(currentTime: 5)

            let position = try XCTUnwrap(camera.currentCameraPosition())
            let constants = try makeConstants(position: position)
            let metrics = try XCTUnwrap(GeoPathMetrics(path: coursePath))
            let center = try XCTUnwrap(screenPoint(of: metrics.sample(atFraction: 0.5).coordinate,
                                                   constants: constants))
            let ahead = try XCTUnwrap(screenPoint(of: metrics.sample(atFraction: 0.6).coordinate,
                                                  constants: constants))

            XCTAssertGreaterThan(ahead.y, center.y,
                                 "Travelling \(name), the point ahead must be up the screen")
            XCTAssertEqual(ahead.x, center.x, accuracy: abs(ahead.y - center.y) * 0.05,
                           "Travelling \(name), the course must be straight up, not sideways")
        }
    }

    // MARK: - Completion and precedence

    @MainActor
    func testCancelCompletesWithFalseExactlyOnce() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var calls: [Bool] = []
        view.followForTesting(path: path,
                              duration: 10,
                              completion: { calls.append($0) },
                              currentTime: 0)
        camera.cancelFollow()
        camera.cancelFollow()

        XCTAssertEqual(calls, [false])
        XCTAssertFalse(view.hasActiveCameraPathFollowForTesting)
    }

    /// A flight is a direct camera command: it takes the camera and resolves
    /// the traversal instead of leaving both writing camera state.
    @MainActor
    func testStartingAFlightCancelsTheFollow() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var followCompleted: Bool?
        view.followForTesting(path: path,
                              duration: 10,
                              completion: { followCompleted = $0 },
                              currentTime: 0)
        camera.fly(to: ImmersiveMapCameraPosition(latitudeDegrees: 10, longitudeDegrees: 10, zoom: 3),
                   options: CameraFlightOptions(duration: 1))

        XCTAssertEqual(followCompleted, false)
        XCTAssertFalse(view.hasActiveCameraPathFollowForTesting)
        XCTAssertTrue(view.hasActiveCameraFlightForTesting)
    }

    @MainActor
    func testStartingASecondFollowSupersedesTheFirst() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var first: Bool?
        var second: Bool?
        view.followForTesting(path: path, duration: 10, completion: { first = $0 }, currentTime: 0)
        view.followForTesting(path: path, duration: 10, completion: { second = $0 }, currentTime: 1)

        XCTAssertEqual(first, false)
        XCTAssertNil(second)
        XCTAssertTrue(view.hasActiveCameraPathFollowForTesting)
    }

    /// The user taking the camera wins, exactly as it does over a flight.
    @MainActor
    func testUserInteractionCancelsTheFollow() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var completed: Bool?
        view.followForTesting(path: path, duration: 10, completion: { completed = $0 }, currentTime: 0)
        view.setPanInteractionActiveForTesting(true)
        view.advanceCameraPathFollowForTesting(currentTime: 1)

        XCTAssertEqual(completed, false)
        XCTAssertFalse(view.hasActiveCameraPathFollowForTesting)
    }

    @MainActor
    func testDegeneratePathCompletesWithFalseWithoutMovingTheCamera() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)
        let before = try XCTUnwrap(camera.currentCameraPosition())

        var completed: Bool?
        let point = GeoCoordinate(latitude: 10, longitude: 10)
        view.followForTesting(path: ImmersiveMapGeoPath(waypoints: [point, point]),
                              duration: 10,
                              completion: { completed = $0 },
                              currentTime: 0)

        XCTAssertEqual(completed, false)
        XCTAssertFalse(view.hasActiveCameraPathFollowForTesting)
        XCTAssertEqual(try XCTUnwrap(camera.currentCameraPosition()).longitudeDegrees,
                       before.longitudeDegrees,
                       accuracy: 1e-9)
    }

    @MainActor
    func testZeroDurationJumpsToTheEndAndCompletes() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        var completed: Bool?
        view.followForTesting(path: path,
                              duration: 0,
                              options: ImmersiveMapCameraFollowOptions(bearing: .unchanged,
                                                                       smoothingHalfLife: 0),
                              completion: { completed = $0 },
                              currentTime: 0)

        XCTAssertEqual(completed, true)
        XCTAssertFalse(view.hasActiveCameraPathFollowForTesting)
        XCTAssertEqual(try longitude(of: camera), 40, accuracy: 1e-3)
    }

    /// A `follow` issued from inside a superseded completion must win: the call
    /// that is still unwinding must not overwrite it.
    @MainActor
    func testFollowStartedFromASupersededCompletionSurvives() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)
        let secondPath = ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 0, longitude: 0),
                                             to: GeoCoordinate(latitude: 40, longitude: 0))

        var innerCompleted: Bool?
        view.followForTesting(path: path, duration: 10, completion: { _ in
            view.followForTesting(path: secondPath,
                                  duration: 10,
                                  options: ImmersiveMapCameraFollowOptions(bearing: .unchanged,
                                                                           smoothingHalfLife: 0),
                                  completion: { innerCompleted = $0 },
                                  currentTime: 1)
        }, currentTime: 0)

        // Superseding the first fires its completion, which starts the second.
        view.followForTesting(path: path, duration: 10, currentTime: 1)

        XCTAssertTrue(view.hasActiveCameraPathFollowForTesting)
        view.advanceCameraPathFollowForTesting(currentTime: 11)
        XCTAssertEqual(innerCompleted, true, "the traversal started from the completion must run")
        XCTAssertEqual(try XCTUnwrap(camera.currentCameraPosition()).latitudeDegrees, 40, accuracy: 1e-2)
    }

    /// A stall must not strand the camera: the frame that ends the traversal
    /// pays back the catch-up the missed frames skipped.
    @MainActor
    func testAStalledFinalFrameStillLandsNearTheDestination() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        view.followForTesting(path: path,
                              duration: 10,
                              options: ImmersiveMapCameraFollowOptions(bearing: .unchanged,
                                                                       smoothingHalfLife: 0.35),
                              currentTime: 0)
        view.advanceCameraPathFollowForTesting(currentTime: 0)
        // One frame, ten seconds later: the display link was asleep the whole
        // traversal.
        view.advanceCameraPathFollowForTesting(currentTime: 10)

        XCTAssertEqual(try longitude(of: camera), 40, accuracy: 0.5)
        XCTAssertFalse(view.hasActiveCameraPathFollowForTesting)
    }

    // MARK: - Render loop

    @MainActor
    func testFollowKeepsTheRenderLoopAwakeUntilItFinishes() throws {
        try skipUnlessMetalAvailable()
        let camera = ImmersiveMapCameraController()
        let view = makeHostView(camera: camera)

        view.followForTesting(path: path, duration: 10, currentTime: 0)
        XCTAssertTrue(view.isCameraAnimationRenderingActiveForTesting)

        view.advanceCameraPathFollowForTesting(currentTime: 10)
        XCTAssertFalse(view.isCameraAnimationRenderingActiveForTesting)
    }

    // MARK: - Helpers

    private func longitude(of camera: ImmersiveMapCameraController) throws -> Double {
        try XCTUnwrap(camera.currentCameraPosition()).longitudeDegrees
    }

    /// A short path from the equator running on the given compass course.
    private static func path(course: Double) -> ImmersiveMapGeoPath? {
        let start = GeoCoordinate(latitude: 0, longitude: 0)
        let radians = course * .pi / 180.0
        let step = 0.4
        let end = GeoCoordinate(latitude: start.latitude + cos(radians) * step,
                                longitude: start.longitude + sin(radians) * step)
        return ImmersiveMapGeoPath(waypoints: [start, end])
    }

    private func makeConstants(position: ImmersiveMapCameraPosition) throws
        -> GeoScreenProjectionMath.FrameConstants {
        let drawSize = CGSize(width: 320, height: 240)
        let center = ImmersiveMapProjection.worldMercator(latitude: position.latitudeDegrees * .pi / 180.0,
                                                          longitude: position.longitudeDegrees * .pi / 180.0)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center,
                                                  zoom: position.zoom,
                                                  bearing: position.bearing,
                                                  pitch: position.pitch)
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: ImmersiveMapSettings.default.presentation)
        let renderCamera = RenderCamera()
        renderCamera.recalculateProjection(aspect: Float(drawSize.width / drawSize.height))
        RenderCameraPoseResolver().updateIfNeeded(camera: renderCamera, cameraState: cameraState)
        let matrix = try XCTUnwrap(renderCamera.cameraMatrix)
        return GeoScreenProjectionMath.FrameConstants(
            drawSize: drawSize,
            cameraUniform: CameraUniform(matrix: matrix, eye: renderCamera.eye, padding: 0),
            resolvedPresentation: presentation)
    }

    private func screenPoint(of coordinate: GeoCoordinate,
                             constants: GeoScreenProjectionMath.FrameConstants) -> SIMD2<Float>? {
        let projected = GeoScreenProjectionMath.project(basis: GeoProjectionBasis(coordinate: coordinate),
                                                        constants: constants)
        guard projected.visible != 0 else { return nil }
        return projected.position
    }

    @MainActor
    private func makeHostView(camera: ImmersiveMapCameraController,
                              zoom: Double? = nil) -> ImmersiveMapNSView {
        let position = zoom.map {
            ImmersiveMapCameraPosition(latitudeDegrees: overview.latitudeDegrees,
                                       longitudeDegrees: overview.longitudeDegrees,
                                       zoom: $0)
        } ?? overview
        let view = ImmersiveMapNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                                      settings: FixtureTiles.settings(),
                                      avatarsController: nil,
                                      cameraPosition: position,
                                      cameraController: camera,
                                      selectionController: nil,
                                      avatarTapAction: nil)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func skipUnlessMetalAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
    }
}

#endif
