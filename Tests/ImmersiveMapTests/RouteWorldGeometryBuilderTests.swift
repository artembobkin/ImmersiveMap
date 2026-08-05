// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// The per-frame CPU build of a route centerline: progress truncation, the
/// altitude lift that must match a scene model anchor, the globe-only
/// invariant, and continuity of a chain of points across the antimeridian.
final class RouteWorldGeometryBuilderTests: XCTestCase {
    private let drawSize = CGSize(width: 800, height: 600)
    private let presentationSettings = ImmersiveMapSettings.default.presentation

    // MARK: - Progress

    func testZeroProgressBuildsNothing() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        let samples = GeoPathSampler.samples(for: equatorPath())

        XCTAssertTrue(RouteWorldGeometryBuilder.build(samples: samples,
                                                      progress: 0,
                                                      constants: constants).isEmpty)
        XCTAssertTrue(RouteWorldGeometryBuilder.build(samples: samples,
                                                      progress: -1,
                                                      constants: constants).isEmpty)
    }

    func testFullProgressBuildsEverySampleAndEndsAtOne() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        let samples = GeoPathSampler.samples(for: equatorPath())
        let points = RouteWorldGeometryBuilder.build(samples: samples,
                                                     progress: 1,
                                                     constants: constants)

        XCTAssertEqual(points.count, samples.count)
        XCTAssertEqual(try XCTUnwrap(points.first).w, 0)
        XCTAssertEqual(try XCTUnwrap(points.last).w, 1)
    }

    func testPartialProgressEndsExactlyAtTheRequestedFraction() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        let samples = GeoPathSampler.samples(for: equatorPath())
        let points = RouteWorldGeometryBuilder.build(samples: samples,
                                                     progress: 0.5,
                                                     constants: constants)

        XCTAssertGreaterThan(points.count, 2)
        XCTAssertLessThan(points.count, samples.count)
        XCTAssertEqual(try XCTUnwrap(points.last).w, 0.5, accuracy: 1e-6)
        for index in 1..<points.count {
            XCTAssertGreaterThan(points[index].w, points[index - 1].w)
        }
    }

    /// A progress that lands inside the first tessellation step still has to
    /// produce a drawable two-point ribbon.
    func testProgressInsideTheFirstSegmentStillBuildsTwoPoints() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        let samples = GeoPathSampler.samples(for: equatorPath())
        let firstStep = samples[1].fraction
        let points = RouteWorldGeometryBuilder.build(samples: samples,
                                                     progress: firstStep * 0.5,
                                                     constants: constants)

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[1].w, Float(firstStep * 0.5), accuracy: 1e-6)
    }

    // MARK: - Altitude lift

    /// Every point must sit at globe radius plus the profile altitude scaled to
    /// render units, which is the same lift `SceneModelAnchorMath` applies.
    func testPointsRideTheAltitudeProfileAboveTheSphere() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        XCTAssertEqual(constants.globe.transition, 0)

        let peakMeters = 400_000.0
        let path = ImmersiveMapGeoPath(waypoints: equatorPath().waypoints, peakAltitudeMeters: peakMeters)
        let samples = GeoPathSampler.samples(for: path)
        let points = RouteWorldGeometryBuilder.build(samples: samples, progress: 1, constants: constants)

        let globeCenter = SIMD3<Float>(0, 0, -constants.globe.radius)
        let unitsPerMeter = 2 * Float.pi * constants.globe.radius
            / Float(ImmersiveMapProjection.earthCircumferenceMeters)

        for (index, point) in points.enumerated() {
            let expectedRadius = constants.globe.radius
                + Float(samples[index].altitudeMeters) * unitsPerMeter
            XCTAssertEqual(simd_length(point.xyz - globeCenter),
                           expectedRadius,
                           accuracy: expectedRadius * 1e-4)
        }

        let apexRadius = simd_length(points[points.count / 2].xyz - globeCenter)
        XCTAssertGreaterThan(apexRadius, constants.globe.radius)
    }

    // MARK: - Invariants

    func testFlatPresentationBuildsNothing() throws {
        let constants = try makeConstants(latitude: 55.75, longitude: 37.61, zoom: 15.0)
        XCTAssertEqual(constants.mode, .flat)

        let samples = GeoPathSampler.samples(for: equatorPath())
        XCTAssertTrue(RouteWorldGeometryBuilder.build(samples: samples,
                                                      progress: 1,
                                                      constants: constants).isEmpty)
    }

    func testFewerThanTwoSamplesBuildNothing() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        XCTAssertTrue(RouteWorldGeometryBuilder.build(samples: [], progress: 1, constants: constants).isEmpty)
    }

    /// Mid-morph the flat term wraps per point, so without the chained unwrap a
    /// path crossing the seam streaks across the whole world.
    func testAntimeridianCrossingKeepsNeighboursClose() throws {
        let constants = try makeConstants(latitude: 0, longitude: 0, zoom: 6.5)
        XCTAssertEqual(constants.mode, .globe)
        XCTAssertGreaterThan(constants.globe.transition, 0)

        let path = ImmersiveMapGeoPath(waypoints: [GeoCoordinate(latitude: 0, longitude: 178),
                                                   GeoCoordinate(latitude: 0, longitude: -178)])
        let points = RouteWorldGeometryBuilder.build(samples: GeoPathSampler.samples(for: path),
                                                     progress: 1,
                                                     constants: constants)

        XCTAssertGreaterThan(points.count, 2)
        let limit = constants.globeMapSize * 0.05
        for index in 1..<points.count {
            XCTAssertLessThan(simd_distance(points[index].xyz, points[index - 1].xyz), limit)
        }
    }

    // MARK: - Helpers

    private func equatorPath() -> ImmersiveMapGeoPath {
        ImmersiveMapGeoPath(waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                                        GeoCoordinate(latitude: 0, longitude: 60)])
    }

    private func makeConstants(latitude: Double,
                               longitude: Double,
                               zoom: Double) throws -> GeoScreenProjectionMath.FrameConstants {
        let center = ImmersiveMapProjection.worldMercator(latitude: latitude * .pi / 180.0,
                                                          longitude: longitude * .pi / 180.0)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center,
                                                  zoom: zoom,
                                                  bearing: 0,
                                                  pitch: 0)
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: presentationSettings)
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: Float(drawSize.width / drawSize.height))
        let poseResolver = RenderCameraPoseResolver()
        poseResolver.updateIfNeeded(camera: camera, cameraState: cameraState)
        let cameraMatrix = try XCTUnwrap(camera.cameraMatrix)
        return GeoScreenProjectionMath.FrameConstants(
            drawSize: drawSize,
            cameraUniform: CameraUniform(matrix: cameraMatrix, eye: camera.eye, padding: 0),
            resolvedPresentation: presentation)
    }
}
