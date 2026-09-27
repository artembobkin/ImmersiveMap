// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class CameraBoundsConstraintTests: XCTestCase {
    private typealias Bounds = ImmersiveMapSettings.CameraSettings.Bounds

    private let moscow = Bounds(southWest: GeoCoordinate(latitude: 55.57, longitude: 37.36),
                                northEast: GeoCoordinate(latitude: 55.92, longitude: 37.86),
                                pullZoomRange: 1...2,
                                pullCurve: .linear)

    func testGlobeBelowThePullRangeTurnsFreely() {
        let constraint = CameraBoundsConstraint(bounds: moscow)
        let sydney = world(latitude: -33.87, longitude: 151.21)

        assertEqual(constraint.apply(to: sydney, zoom: 0), sydney)
        assertEqual(constraint.apply(to: sydney, zoom: 1), sydney)
    }

    /// Halfway through a linear pull the reachable area has closed half of
    /// the way from the edge of the world to the region.
    func testLinearPullClosesHalfwayInTheMiddleOfTheRange() {
        var bounds = moscow
        bounds.southWest = GeoCoordinate(latitude: 0, longitude: 0)
        bounds.northEast = GeoCoordinate(latitude: 0, longitude: 0)
        let constraint = CameraBoundsConstraint(bounds: bounds)

        let held = constraint.apply(to: SIMD2<Double>(0.9, 0.1), zoom: 1.5)
        XCTAssertEqual(held.x, 0.5 + 0.25, accuracy: 1e-9)
        XCTAssertEqual(held.y, 0.5 * 0.5, accuracy: 1e-9)
    }

    func testCenterIsInsideTheRegionFromTheUpperBoundOn() {
        let constraint = CameraBoundsConstraint(bounds: moscow)
        let paris = world(latitude: 48.86, longitude: 2.35)

        for zoom in [2.0, 14.0] {
            let (latitude, longitude) = degrees(constraint.apply(to: paris, zoom: zoom))
            XCTAssertEqual(latitude, 55.57, accuracy: 0.0001)
            XCTAssertEqual(longitude, 37.36, accuracy: 0.0001)
        }
    }

    func testCenterInsideTheRegionIsLeftAlone() {
        let constraint = CameraBoundsConstraint(bounds: moscow)
        let kremlin = world(latitude: 55.75, longitude: 37.62)

        assertEqual(constraint.apply(to: kremlin, zoom: 18), kremlin)
    }

    func testEqualBoundsSwitchAtThatZoom() {
        var bounds = moscow
        bounds.pullZoomRange = 0...0
        let constraint = CameraBoundsConstraint(bounds: bounds)

        let held = constraint.apply(to: world(latitude: -33.87, longitude: 151.21), zoom: 0)
        let (latitude, longitude) = degrees(held)
        XCTAssertEqual(latitude, 55.57, accuracy: 0.0001)
        XCTAssertEqual(longitude, 37.86, accuracy: 0.0001)
    }

    func testRegionAcrossTheAntimeridianClampsTheShortWay() {
        let chukotka = Bounds(southWest: GeoCoordinate(latitude: 64, longitude: 170),
                              northEast: GeoCoordinate(latitude: 68, longitude: -170))
        let constraint = CameraBoundsConstraint(bounds: chukotka)

        let (_, inside) = degrees(constraint.apply(to: world(latitude: 66, longitude: 179), zoom: 10))
        XCTAssertEqual(inside, 179, accuracy: 0.0001)
        let (_, east) = degrees(constraint.apply(to: world(latitude: 66, longitude: -160), zoom: 10))
        XCTAssertEqual(east, -170, accuracy: 0.0001)
        let (_, west) = degrees(constraint.apply(to: world(latitude: 66, longitude: 160), zoom: 10))
        XCTAssertEqual(west, 170, accuracy: 0.0001)
    }

    /// With a hard edge, zooming in far from the region draws the center
    /// toward it, so the controller re-applies the bounds after a zoom, not
    /// only after a pan.
    func testHardEdgeZoomingInDrawsTheCenterToTheRegion() {
        var bounds = moscow
        bounds.edgeBehavior = .hard
        var settings = ImmersiveMapSettings.default.camera
        settings.bounds = bounds
        let controller = CameraStateController(settings: settings)
        controller.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 48.86,
                                                                longitudeDegrees: 2.35,
                                                                zoom: 0,
                                                                bearing: 0,
                                                                pitch: 0))
        XCTAssertEqual(controller.getLatLonDeg().lonDeg, 2.35, accuracy: 0.0001)

        controller.zoom(delta: 14)

        let position = controller.getLatLonDeg()
        XCTAssertEqual(position.latDeg, 55.57, accuracy: 0.05)
        XCTAssertEqual(position.lonDeg, 37.36, accuracy: 0.05)
    }

    // MARK: - Elastic edge

    func testStretchIsFreeUpToTheEdgeAndDampedPastIt() {
        let constraint = CameraBoundsConstraint(bounds: equatorPoint)
        let stretch = 0.1

        let inside = constraint.resist(from: SIMD2(0.5, 0.5), to: SIMD2(0.5, 0.5), zoom: 5, maximumStretch: stretch)
        XCTAssertEqual(inside.x, 0.5, accuracy: 1e-12)

        // A drag of one reach past the edge shows half of it: d = L u / (L + u).
        let once = constraint.resist(from: SIMD2(0.5, 0.5), to: SIMD2(0.6, 0.5), zoom: 5, maximumStretch: stretch)
        XCTAssertEqual(once.x, 0.55, accuracy: 1e-12)

        // The same drag in ten steps lands at the same point: the band keeps
        // no state between moves.
        var stepped = SIMD2<Double>(0.5, 0.5)
        for _ in 0..<10 {
            stepped = constraint.resist(from: stepped, to: stepped + SIMD2(0.01, 0), zoom: 5, maximumStretch: stretch)
        }
        XCTAssertEqual(stepped.x, 0.55, accuracy: 1e-9)
    }

    func testStretchNeverReachesItsReach() {
        let constraint = CameraBoundsConstraint(bounds: equatorPoint)

        var center = SIMD2<Double>(0.5, 0.5)
        for _ in 0..<1000 {
            center = constraint.resist(from: center, to: center + SIMD2(0, 0.05), zoom: 5, maximumStretch: 0.1)
        }
        XCTAssertLessThan(center.y, 0.6)
        XCTAssertGreaterThan(center.y, 0.59)
    }

    func testMoveBackTowardTheAreaIsFree() {
        let constraint = CameraBoundsConstraint(bounds: equatorPoint)

        let back = constraint.resist(from: SIMD2(0.58, 0.5), to: SIMD2(0.53, 0.5), zoom: 5, maximumStretch: 0.1)
        XCTAssertEqual(back.x, 0.53, accuracy: 1e-12)
    }

    /// A zoom can leave the center farther out than the band reaches. A drag
    /// outward then does nothing rather than snapping it in.
    func testCenterBeyondTheReachMovesNoFurtherOut() {
        let constraint = CameraBoundsConstraint(bounds: equatorPoint)

        let held = constraint.resist(from: SIMD2(0.8, 0.5), to: SIMD2(0.85, 0.5), zoom: 5, maximumStretch: 0.1)
        XCTAssertEqual(held.x, 0.8, accuracy: 1e-12)
    }

    func testElasticControllerLetsZoomLeaveTheCenterAndPullsItBack() {
        let controller = elasticController(pullProgression: 2)
        controller.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 48.86,
                                                                longitudeDegrees: 2.35,
                                                                zoom: 14,
                                                                bearing: 0,
                                                                pitch: 0))
        XCTAssertEqual(controller.getLatLonDeg().lonDeg, 2.35, accuracy: 0.0001)

        var previous = controller.getLatLonDeg().lonDeg
        var frames = 0
        while controller.advanceBoundsPull(deltaTime: 1.0 / 60) {
            let longitude = controller.getLatLonDeg().lonDeg
            XCTAssertGreaterThanOrEqual(longitude, previous, "The pull only ever moves toward the region")
            previous = longitude
            frames += 1
            XCTAssertLessThan(frames, 600, "The pull must settle")
        }
        // Far out the pull is at its cap, so it is not a one-frame jump.
        XCTAssertGreaterThan(frames, 10)
        let settled = controller.getLatLonDeg()
        XCTAssertEqual(settled.latDeg, 55.57, accuracy: 0.0001)
        XCTAssertEqual(settled.lonDeg, 37.36, accuracy: 0.0001)
        XCTAssertFalse(controller.advanceBoundsPull(deltaTime: 1.0 / 60))
    }

    /// Near the edge the pull closes half the gap every `pullHalfLife`; with
    /// a progression it closes a far gap faster, as a share of that gap.
    func testPullGrowsWithTheDistance() {
        func closedShare(startingPointsOut points: Double, progression: Double) -> Double {
            let controller = elasticController(pullProgression: progression)
            // The region's west edge at zoom 14, `points` screen points out.
            let worldPerPoint = 0.5 * 0.05 * 0.5 * 0.1 / pow(2.0, 14)
            let edge = world(latitude: 55.75, longitude: 37.36)
            controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: edge - SIMD2(points * worldPerPoint, 0),
                                                              zoom: 14,
                                                              bearing: 0,
                                                              pitch: 0))
            let before = edge.x - controller.cameraState.centerWorldMercator.x
            _ = controller.advanceBoundsPull(deltaTime: 0.35)
            let after = edge.x - controller.cameraState.centerWorldMercator.x
            return 1 - after / before
        }

        XCTAssertEqual(closedShare(startingPointsOut: 1, progression: 2), 0.5, accuracy: 0.02)
        XCTAssertEqual(closedShare(startingPointsOut: 200, progression: 0), 0.5, accuracy: 0.001)
        // (1 + 200 / 200)^2 = 4 half-lives in one pullHalfLife.
        XCTAssertEqual(closedShare(startingPointsOut: 200, progression: 2), 1 - 1.0 / 16, accuracy: 0.001)
    }

    private func elasticController(pullProgression: Double) -> CameraStateController {
        var bounds = moscow
        bounds.edgeBehavior = .elastic(maximumStretch: 200, pullHalfLife: 0.35, pullProgression: pullProgression)
        var settings = ImmersiveMapSettings.default.camera
        settings.bounds = bounds
        return CameraStateController(settings: settings)
    }

    func testPresetCurvesMeetTheirEndsAndShape() {
        for curve in [Bounds.PullCurve.linear, .easeIn, .easeOut, .easeInOut] {
            XCTAssertEqual(curve.value(at: 0), 0, accuracy: 1e-9)
            XCTAssertEqual(curve.value(at: 1), 1, accuracy: 1e-9)
        }
        XCTAssertEqual(Bounds.PullCurve.linear.value(at: 0.3), 0.3, accuracy: 1e-6)
        XCTAssertEqual(Bounds.PullCurve.easeInOut.value(at: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertLessThan(Bounds.PullCurve.easeIn.value(at: 0.5), 0.5)
        XCTAssertGreaterThan(Bounds.PullCurve.easeOut.value(at: 0.5), 0.5)
    }

    /// A curve whose y leaves 0...1 overshoots, but the pull never opens past
    /// the whole world or closes past the region.
    func testOvershootingCurveIsClampedToTheRegion() {
        var bounds = moscow
        bounds.pullCurve = Bounds.PullCurve(x1: 0.3, y1: 1.8, x2: 0.6, y2: 1.4)
        let constraint = CameraBoundsConstraint(bounds: bounds)

        XCTAssertGreaterThan(bounds.pullCurve.value(at: 0.5), 1)
        XCTAssertEqual(constraint.pull(atZoom: 1.5), 1)
    }

    /// A region shrunk to the point (0, 0), strict from zoom 2: at zoom 5 the
    /// area is the world point (0.5, 0.5).
    private var equatorPoint: Bounds {
        Bounds(southWest: GeoCoordinate(latitude: 0, longitude: 0),
               northEast: GeoCoordinate(latitude: 0, longitude: 0))
    }

    private func world(latitude: Double, longitude: Double) -> SIMD2<Double> {
        ImmersiveMapProjection.worldMercator(latitude: latitude * .pi / 180,
                                             longitude: longitude * .pi / 180)
    }

    private func degrees(_ world: SIMD2<Double>) -> (Double, Double) {
        (ImmersiveMapProjection.latitude(fromNormalizedWorldY: world.y) * 180 / .pi,
         ImmersiveMapProjection.longitude(fromNormalizedWorldX: world.x) * 180 / .pi)
    }

    private func assertEqual(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: 1e-12, file: file, line: line)
    }
}
