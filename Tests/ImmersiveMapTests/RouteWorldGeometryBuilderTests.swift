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
                                                      constants: constants).points.isEmpty)
        XCTAssertTrue(RouteWorldGeometryBuilder.build(samples: samples,
                                                      progress: -1,
                                                      constants: constants).points.isEmpty)
    }

    func testFullProgressBuildsEverySampleAndEndsAtOne() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        let samples = GeoPathSampler.samples(for: equatorPath())
        let geometry = RouteWorldGeometryBuilder.build(samples: samples,
                                                     progress: 1,
                                                     constants: constants)
        let points = geometry.points

        XCTAssertEqual(points.count, samples.count)
        XCTAssertEqual(try XCTUnwrap(points.first).w, 0)
        XCTAssertEqual(try XCTUnwrap(points.last).w, 1)
    }

    func testPartialProgressEndsExactlyAtTheRequestedFraction() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        let samples = GeoPathSampler.samples(for: equatorPath())
        let geometry = RouteWorldGeometryBuilder.build(samples: samples,
                                                     progress: 0.5,
                                                     constants: constants)
        let points = geometry.points

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
        let geometry = RouteWorldGeometryBuilder.build(samples: samples,
                                                     progress: firstStep * 0.5,
                                                     constants: constants)
        let points = geometry.points

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
        let geometry = RouteWorldGeometryBuilder.build(samples: samples, progress: 1, constants: constants)
        let points = geometry.points

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
                                                      constants: constants).points.isEmpty)
    }

    func testFewerThanTwoSamplesBuildNothing() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        XCTAssertTrue(RouteWorldGeometryBuilder.build(samples: [], progress: 1, constants: constants).points.isEmpty)
    }

    /// Mid-morph the flat term wraps per point, so without the chained unwrap a
    /// path crossing the seam streaks across the whole world.
    func testAntimeridianCrossingKeepsNeighboursClose() throws {
        let constants = try makeConstants(latitude: 0, longitude: 0, zoom: 6.5)
        XCTAssertEqual(constants.mode, .globe)
        XCTAssertGreaterThan(constants.globe.transition, 0)

        let path = ImmersiveMapGeoPath(waypoints: [GeoCoordinate(latitude: 0, longitude: 178),
                                                   GeoCoordinate(latitude: 0, longitude: -178)])
        let geometry = RouteWorldGeometryBuilder.build(samples: GeoPathSampler.samples(for: path),
                                                     progress: 1,
                                                     constants: constants)
        let points = geometry.points

        XCTAssertGreaterThan(points.count, 2)
        let limit = constants.globeMapSize * 0.05
        for index in 1..<points.count {
            XCTAssertLessThan(simd_distance(points[index].xyz, points[index - 1].xyz), limit)
        }
    }

    // MARK: - Presentation store

    /// A route added and animated before its first frame must animate, not snap:
    /// this is the `add(progress: 0)` + `setProgress(1, duration:)` pair every
    /// caller writes.
    func testRouteAddedAndAnimatedInTheSameSnapshotAnimates() {
        let store = RoutePresentationStateStore()
        let route = ImmersiveMapRoute(id: 1, path: equatorPath(), progress: 1)
        store.apply(snapshot: RoutesSnapshot(routes: [route],
                                             progressAnimationsById: [
                                                 1: RouteProgressAnimationRequest(startProgress: 0, duration: 4)
                                             ],
                                             removedIds: [],
                                             version: 1),
                    time: 100)

        XCTAssertTrue(store.hasActiveAnimations)
        XCTAssertEqual(store.presentedEntries(at: 100)[0].progress, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(store.presentedEntries(at: 102)[0].progress, 0)
        XCTAssertLessThan(store.presentedEntries(at: 102)[0].progress, 1)
        XCTAssertEqual(store.presentedEntries(at: 104)[0].progress, 1, accuracy: 1e-9)
        XCTAssertFalse(store.hasActiveAnimations)
    }

    func testRouteAddedWithoutARequestSnapsToItsProgress() {
        let store = RoutePresentationStateStore()
        let route = ImmersiveMapRoute(id: 1, path: equatorPath(), progress: 0.4)
        store.apply(snapshot: RoutesSnapshot(routes: [route],
                                             progressAnimationsById: [:],
                                             removedIds: [],
                                             version: 1),
                    time: 0)

        XCTAssertFalse(store.hasActiveAnimations)
        XCTAssertEqual(store.presentedEntries(at: 0)[0].progress, 0.4, accuracy: 1e-9)
    }

    // MARK: - Screen arc length

    /// Dashes are measured along the projected centerline, so the length must
    /// start at zero, never go backwards, and match the sum of the projected
    /// segment lengths.
    func testScreenLengthsAccumulateAlongTheProjectedCenterline() throws {
        let constants = try makeConstants(latitude: 0, longitude: 30, zoom: 1.0)
        let geometry = RouteWorldGeometryBuilder.build(samples: GeoPathSampler.samples(for: equatorPath()),
                                                       progress: 1,
                                                       constants: constants)

        XCTAssertEqual(geometry.screenLengthsPx.count, geometry.points.count)
        XCTAssertEqual(try XCTUnwrap(geometry.screenLengthsPx.first), 0)
        for index in 1..<geometry.screenLengthsPx.count {
            XCTAssertGreaterThanOrEqual(geometry.screenLengthsPx[index], geometry.screenLengthsPx[index - 1])
        }

        var expected: Float = 0
        let halfViewport = constants.viewport * 0.5
        var previous: SIMD2<Float>?
        for point in geometry.points {
            let clip = constants.cameraUniform.matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
            guard clip.w > 1e-4 else {
                previous = nil
                continue
            }
            let screen = SIMD2<Float>(clip.x, clip.y) / clip.w * halfViewport
            if let previous {
                expected += simd_distance(previous, screen)
            }
            previous = screen
        }
        XCTAssertEqual(try XCTUnwrap(geometry.screenLengthsPx.last), expected, accuracy: 1e-3)
        XCTAssertGreaterThan(expected, 1)
    }

    /// The whole point of measuring on screen: zooming in must lengthen the
    /// pixel run of the same geometry, so a dash keeps its size instead of
    /// stretching with the world.
    func testScreenLengthGrowsWithZoomForTheSamePath() throws {
        let samples = GeoPathSampler.samples(for: ImmersiveMapGeoPath(
            waypoints: [GeoCoordinate(latitude: 0, longitude: 0),
                        GeoCoordinate(latitude: 0, longitude: 4)]))

        let farConstants = try makeConstants(latitude: 0, longitude: 2, zoom: 1.0)
        let nearConstants = try makeConstants(latitude: 0, longitude: 2, zoom: 4.0)
        let far = RouteWorldGeometryBuilder.build(samples: samples, progress: 1, constants: farConstants)
        let near = RouteWorldGeometryBuilder.build(samples: samples, progress: 1, constants: nearConstants)

        let farLength = try XCTUnwrap(far.screenLengthsPx.last)
        let nearLength = try XCTUnwrap(near.screenLengthsPx.last)
        XCTAssertGreaterThan(farLength, 0)
        XCTAssertGreaterThan(nearLength, farLength * 2)
    }

    // MARK: - Dash period

    func testDashPixelsScaleWithTheDisplayAndCollapseWhenDegenerate() {
        let dash = ImmersiveMapRouteDash(dashPoints: 8, gapPoints: 4)
        XCTAssertEqual(RouteRenderSubsystem.dashPixels(dash, pixelsPerPoint: 2), SIMD2<Float>(16, 8))
        XCTAssertEqual(RouteRenderSubsystem.dashPixels(dash, pixelsPerPoint: 1), SIMD2<Float>(8, 4))

        // A pattern without a gap, or without a dash, is a solid line; passing
        // it through as a zero period keeps the shader branch-free.
        XCTAssertEqual(RouteRenderSubsystem.dashPixels(ImmersiveMapRouteDash(dashPoints: 8, gapPoints: 0),
                                                       pixelsPerPoint: 2),
                       SIMD2<Float>(0, 0))
        XCTAssertEqual(RouteRenderSubsystem.dashPixels(ImmersiveMapRouteDash(dashPoints: 0, gapPoints: 4),
                                                       pixelsPerPoint: 2),
                       SIMD2<Float>(0, 0))
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
