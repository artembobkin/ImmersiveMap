// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Great-circle interpolation and forward azimuth. The interpolation behaviour
/// is the one scene model moves relied on before the math moved out of
/// `SceneModelAnimationMath` into `Geo`, so the edge cases (antimeridian,
/// poles, antipodes) are pinned here.
final class GeoGreatCircleMathTests: XCTestCase {

    // MARK: - Interpolation

    func testProgressBoundsReturnEndpointsExactly() {
        let start = GeoCoordinate(latitude: 12.5, longitude: -30.25)
        let target = GeoCoordinate(latitude: -40.0, longitude: 150.0)

        XCTAssertEqual(GeoGreatCircleMath.coordinate(from: start, to: target, progress: 0), start)
        XCTAssertEqual(GeoGreatCircleMath.coordinate(from: start, to: target, progress: 1), target)
        XCTAssertEqual(GeoGreatCircleMath.coordinate(from: start, to: target, progress: -5), start)
        XCTAssertEqual(GeoGreatCircleMath.coordinate(from: start, to: target, progress: 5), target)
    }

    func testEquatorMidpointStaysOnTheEquator() {
        let mid = GeoGreatCircleMath.coordinate(from: GeoCoordinate(latitude: 0, longitude: 0),
                                                to: GeoCoordinate(latitude: 0, longitude: 60),
                                                progress: 0.5)
        XCTAssertEqual(mid.latitude, 0, accuracy: 1e-9)
        XCTAssertEqual(mid.longitude, 30, accuracy: 1e-9)
    }

    /// A lat/lon lerp would run the long way around the globe here.
    func testAntimeridianTakesTheShortArc() {
        let mid = GeoGreatCircleMath.coordinate(from: GeoCoordinate(latitude: 0, longitude: 179),
                                                to: GeoCoordinate(latitude: 0, longitude: -179),
                                                progress: 0.5)
        XCTAssertEqual(mid.latitude, 0, accuracy: 1e-9)
        XCTAssertEqual(abs(mid.longitude), 180, accuracy: 1e-9)
    }

    func testPoleCrossingKeepsTheMidpointOnTheMeridian() {
        let mid = GeoGreatCircleMath.coordinate(from: GeoCoordinate(latitude: 80, longitude: 0),
                                                to: GeoCoordinate(latitude: 80, longitude: 180),
                                                progress: 0.5)
        XCTAssertEqual(mid.latitude, 90, accuracy: 1e-6)
    }

    func testAntipodalEndpointsFallBackToALatLonLerp() {
        let mid = GeoGreatCircleMath.coordinate(from: GeoCoordinate(latitude: 10, longitude: 0),
                                                to: GeoCoordinate(latitude: -10, longitude: 180),
                                                progress: 0.5)
        XCTAssertFalse(mid.latitude.isNaN)
        XCTAssertFalse(mid.longitude.isNaN)
        XCTAssertEqual(mid.latitude, 0, accuracy: 1e-9)
    }

    func testCoincidentEndpointsReturnTheStart() {
        let point = GeoCoordinate(latitude: 33.3, longitude: 44.4)
        XCTAssertEqual(GeoGreatCircleMath.coordinate(from: point, to: point, progress: 0.5), point)
    }

    // MARK: - Central angle

    func testCentralAngleIsAccurateForShortArcs() {
        // One kilometre along the equator: acos(dot) in Float would collapse
        // this to noise, which is why the half-chord form is used.
        let oneKilometreDegrees = 1000.0 / (ImmersiveMapProjection.earthCircumferenceMeters / 360.0)
        let angle = GeoGreatCircleMath.centralAngle(from: GeoCoordinate(latitude: 0, longitude: 0),
                                                    to: GeoCoordinate(latitude: 0, longitude: oneKilometreDegrees))
        XCTAssertEqual(angle, oneKilometreDegrees * .pi / 180.0, accuracy: 1e-12)
    }

    func testCentralAngleOfAntipodesIsPi() {
        let angle = GeoGreatCircleMath.centralAngle(from: GeoCoordinate(latitude: 0, longitude: 0),
                                                    to: GeoCoordinate(latitude: 0, longitude: 180))
        XCTAssertEqual(angle, .pi, accuracy: 1e-9)
    }

    // MARK: - Bearing

    func testBearingCardinalDirections() {
        let origin = GeoCoordinate(latitude: 0, longitude: 0)
        XCTAssertEqual(GeoGreatCircleMath.bearingDegrees(from: origin,
                                                         to: GeoCoordinate(latitude: 1, longitude: 0)),
                       0, accuracy: 1e-9)
        XCTAssertEqual(GeoGreatCircleMath.bearingDegrees(from: origin,
                                                         to: GeoCoordinate(latitude: 0, longitude: 1)),
                       90, accuracy: 1e-9)
        XCTAssertEqual(GeoGreatCircleMath.bearingDegrees(from: origin,
                                                         to: GeoCoordinate(latitude: -1, longitude: 0)),
                       180, accuracy: 1e-9)
        XCTAssertEqual(GeoGreatCircleMath.bearingDegrees(from: origin,
                                                         to: GeoCoordinate(latitude: 0, longitude: -1)),
                       270, accuracy: 1e-9)
    }

    func testBearingAcrossTheAntimeridianPointsEast() {
        let bearing = GeoGreatCircleMath.bearingDegrees(from: GeoCoordinate(latitude: 0, longitude: 179.9),
                                                        to: GeoCoordinate(latitude: 0, longitude: -179.9))
        XCTAssertEqual(bearing, 90, accuracy: 1e-9)
    }

    func testBearingOfCoincidentPointsIsZero() {
        let point = GeoCoordinate(latitude: 5, longitude: 5)
        XCTAssertEqual(GeoGreatCircleMath.bearingDegrees(from: point, to: point), 0, accuracy: 1e-12)
    }
}
