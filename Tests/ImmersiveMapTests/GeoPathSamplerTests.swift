// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The sampler is the single source of "where is fraction f on this path",
/// shared by the drawn ribbon and by the model flying along it, so its
/// parameterization, altitude profile and derivatives are pinned here.
final class GeoPathSamplerTests: XCTestCase {

    // MARK: - Degenerate paths

    func testFewerThanTwoWaypointsProduceNoMetrics() {
        XCTAssertNil(GeoPathMetrics(path: ImmersiveMapGeoPath(waypoints: [])))
        XCTAssertNil(GeoPathMetrics(path: ImmersiveMapGeoPath(waypoints: [GeoCoordinate(latitude: 1, longitude: 2)])))
        XCTAssertTrue(GeoPathSampler.samples(for: ImmersiveMapGeoPath(waypoints: [])).isEmpty)
    }

    func testCoincidentWaypointsProduceNoMetrics() {
        let point = GeoCoordinate(latitude: 10, longitude: 20)
        XCTAssertNil(GeoPathMetrics(path: ImmersiveMapGeoPath(waypoints: [point, point, point])))
    }

    func testDuplicateWaypointsAreDroppedWithoutBreakingTheParameterization() throws {
        let start = GeoCoordinate(latitude: 0, longitude: 0)
        let end = GeoCoordinate(latitude: 0, longitude: 40)
        let metrics = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(waypoints: [start, start, end, end])))

        XCTAssertEqual(metrics.waypoints.count, 2)
        XCTAssertEqual(metrics.sample(atFraction: 0).coordinate.longitude, 0, accuracy: 1e-9)
        XCTAssertEqual(metrics.sample(atFraction: 1).coordinate.longitude, 40, accuracy: 1e-9)
    }

    // MARK: - Parameterization

    func testFractionsRunFromZeroToOneStrictlyIncreasing() throws {
        let samples = GeoPathSampler.samples(for: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: 55.75, longitude: 37.61),
                        GeoCoordinate(latitude: 37.77, longitude: -122.41)]))

        XCTAssertGreaterThan(samples.count, 2)
        XCTAssertEqual(try XCTUnwrap(samples.first).fraction, 0)
        XCTAssertEqual(try XCTUnwrap(samples.last).fraction, 1)
        for index in 1..<samples.count {
            XCTAssertGreaterThan(samples[index].fraction, samples[index - 1].fraction)
        }
    }

    func testSampleCountGrowsWithPathLengthAndStaysBounded() throws {
        let shortPath = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                        GeoCoordinate(latitude: 0, longitude: 0.01)])))
        let longPath = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: -90, longitude: 0),
                        GeoCoordinate(latitude: 90, longitude: 0)])))

        XCTAssertEqual(shortPath.sampleCount, 2)
        XCTAssertGreaterThan(longPath.sampleCount, shortPath.sampleCount)
        XCTAssertLessThanOrEqual(longPath.sampleCount, GeoPathMetrics.maximumSampleCount)
        // 180 degrees at a 0.25 degree step.
        XCTAssertEqual(longPath.sampleCount, 721)
    }

    func testSampleFollowsTheGreatCircleOfItsSegment() throws {
        let start = GeoCoordinate(latitude: 55.75, longitude: 37.61)
        let end = GeoCoordinate(latitude: 37.77, longitude: -122.41)
        let metrics = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(waypoints: [start, end])))

        for fraction in [0.1, 0.25, 0.5, 0.9] {
            let expected = GeoGreatCircleMath.coordinate(from: start, to: end, progress: fraction)
            let sample = metrics.sample(atFraction: fraction)
            XCTAssertEqual(sample.coordinate.latitude, expected.latitude, accuracy: 1e-9)
            XCTAssertEqual(sample.coordinate.longitude, expected.longitude, accuracy: 1e-9)
        }
    }

    /// Waypoints are placed by arc length, not by index: a 2:1 pair of segments
    /// puts the middle waypoint at two thirds of the path.
    func testMultiWaypointPathIsParameterizedByArcLength() throws {
        let first = GeoCoordinate(latitude: 0, longitude: 0)
        let middle = GeoCoordinate(latitude: 0, longitude: 40)
        let last = GeoCoordinate(latitude: 0, longitude: 60)
        let metrics = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(waypoints: [first, middle, last])))

        let atMiddle = metrics.sample(atFraction: 2.0 / 3.0)
        XCTAssertEqual(atMiddle.coordinate.longitude, 40, accuracy: 1e-6)
        XCTAssertEqual(metrics.sample(atFraction: 1.0 / 3.0).coordinate.longitude, 20, accuracy: 1e-6)
    }

    // MARK: - Altitude profile

    func testAltitudeProfileStartsAndEndsAtBaseAndCrestsInTheMiddle() {
        let path = ImmersiveMapGeoPath(waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                                                   GeoCoordinate(latitude: 0, longitude: 90)],
                                       baseAltitudeMeters: 1_000,
                                       peakAltitudeMeters: 400_000)

        XCTAssertEqual(path.altitudeMeters(atFraction: 0), 1_000, accuracy: 1e-9)
        XCTAssertEqual(path.altitudeMeters(atFraction: 1), 1_000, accuracy: 1e-9)
        XCTAssertEqual(path.altitudeMeters(atFraction: 0.5), 401_000, accuracy: 1e-9)
    }

    func testFlatProfileKeepsTheBaseAltitudeEverywhere() throws {
        let metrics = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                        GeoCoordinate(latitude: 0, longitude: 30)],
            baseAltitudeMeters: 500)))

        for fraction in [0.0, 0.3, 0.5, 1.0] {
            XCTAssertEqual(metrics.sample(atFraction: fraction).altitudeMeters, 500, accuracy: 1e-9)
            XCTAssertEqual(metrics.sample(atFraction: fraction).pitchDegrees, 0, accuracy: 1e-9)
        }
    }

    // MARK: - Derivatives

    func testHeadingAlongTheEquatorPointsEastEverywhere() throws {
        let metrics = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                        GeoCoordinate(latitude: 0, longitude: 60)])))

        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(metrics.sample(atFraction: fraction).headingDegrees, 90, accuracy: 1e-6)
        }
    }

    func testPitchClimbsOnTheFirstHalfAndDescendsOnTheSecond() throws {
        let metrics = try XCTUnwrap(GeoPathMetrics(path: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                        GeoCoordinate(latitude: 0, longitude: 90)],
            peakAltitudeMeters: 400_000)))

        XCTAssertGreaterThan(metrics.sample(atFraction: 0.1).pitchDegrees, 0)
        XCTAssertEqual(metrics.sample(atFraction: 0.5).pitchDegrees, 0, accuracy: 1e-6)
        XCTAssertLessThan(metrics.sample(atFraction: 0.9).pitchDegrees, 0)
    }

    func testSamplesCarryAProjectionBasisMatchingTheirCoordinate() throws {
        let samples = GeoPathSampler.samples(for: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: 10, longitude: 20),
                        GeoCoordinate(latitude: -10, longitude: 40)]))

        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.basis, GeoProjectionBasis(coordinate: sample.coordinate))
    }
}
