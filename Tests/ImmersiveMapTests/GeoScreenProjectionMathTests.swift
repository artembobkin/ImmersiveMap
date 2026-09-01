// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// GeoScreenProjectionMath must project a coordinate with the same formulas as
/// the renderer's vertex path: flat world, globe sphere, morph wave, and soft
/// horizon. The camera is assembled as in the renderer (RenderCamera + PoseResolver),
/// precedent: ZoomAnchorMathTests.projectToScreen.
final class GeoScreenProjectionMathTests: XCTestCase {
    private let drawSize = CGSize(width: 800, height: 600)
    private let presentationSettings = ImmersiveMapSettings.default.presentation

    // MARK: - Flat

    func testFlatCenterProjectsToViewportCenter() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 55.75, longitude: 37.61, zoom: 15.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        let point = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 55.75, longitude: 37.61)),
            constants: environment.constants)

        XCTAssertNotEqual(point.visible, 0)
        XCTAssertEqual(point.visibilityAlpha, 1.0)
        XCTAssertEqual(point.position.x, Float(drawSize.width) * 0.5, accuracy: 0.5)
        XCTAssertEqual(point.position.y, Float(drawSize.height) * 0.5, accuracy: 0.5)
    }

    func testFlatOffsetMatchesImmersiveMapProjectionFlatWorldPosition() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 40.0, longitude: -73.9, zoom: 14.2))
        XCTAssertEqual(environment.constants.mode, .flat)
        let markerLatitude = 40.02
        let markerLongitude = -73.85

        let point = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: markerLatitude,
                                                                longitude: markerLongitude)),
            constants: environment.constants)

        let flatWorld = ImmersiveMapProjection.flatWorldPosition(
            latitude: markerLatitude * .pi / 180.0,
            longitude: markerLongitude * .pi / 180.0,
            flatRenderPan: environment.presentation.flatRenderState.pan,
            renderMapSize: environment.presentation.flatRenderState.renderMapSize)
        let expected = try XCTUnwrap(screenPoint(worldPosition: SIMD3<Float>(flatWorld.x, flatWorld.y, 0.0),
                                                 constants: environment.constants))

        XCTAssertNotEqual(point.visible, 0)
        XCTAssertEqual(point.position.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(point.position.y, expected.y, accuracy: 0.01)
    }

    /// A marker on the other side of the antimeridian from the camera must,
    /// via wrap, end up near the screen center rather than across the world.
    func testFlatAntimeridianWrapKeepsMarkerNearCamera() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 179.9, zoom: 10.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        let point = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0.0, longitude: -179.9)),
            constants: environment.constants)

        XCTAssertNotEqual(point.visible, 0)
        XCTAssertGreaterThan(point.position.x, Float(drawSize.width) * 0.5)
        XCTAssertLessThan(point.position.x, Float(drawSize.width))
        XCTAssertEqual(point.position.y, Float(drawSize.height) * 0.5, accuracy: 0.5)

        // The equivalent "unwrapped" longitude must yield the same point.
        let unwrapped = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0.0, longitude: 180.1)),
            constants: environment.constants)
        XCTAssertNotEqual(unwrapped.visible, 0)
        XCTAssertEqual(point.position.x, unwrapped.position.x, accuracy: 0.01)
        XCTAssertEqual(point.position.y, unwrapped.position.y, accuracy: 0.01)
    }

    /// A plane point far behind the tilted camera yields clip.w <= 0
    /// and must be marked invisible.
    func testFlatPointFarBehindTiltedCameraIsInvisible() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: 16.0, pitch: 1.2))
        XCTAssertEqual(environment.constants.mode, .flat)

        var foundInvisible = false
        for latitude in stride(from: 1.0, through: 85.0, by: 1.0) {
            for signedLatitude in [latitude, -latitude] {
                let point = GeoScreenProjectionMath.project(
                    basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: signedLatitude,
                                                                        longitude: 0.0)),
                    constants: environment.constants)
                if point.visible == 0 {
                    foundInvisible = true
                    XCTAssertEqual(point.visibilityAlpha, 0.0)
                }
            }
        }
        XCTAssertTrue(foundInvisible,
                      "Expected at least one point behind the camera with clip.w <= 0")
    }

    // MARK: - Globe

    func testGlobeFrontPointVisibleWithFullAlphaAtViewportCenter() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 10.0, longitude: 20.0, zoom: 1.0))
        XCTAssertEqual(environment.constants.mode, .globe)
        XCTAssertEqual(environment.constants.globe.transition, 0.0)

        let point = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 10.0, longitude: 20.0)),
            constants: environment.constants)

        XCTAssertNotEqual(point.visible, 0)
        XCTAssertEqual(point.visibilityAlpha, 1.0)
        XCTAssertEqual(point.position.x, Float(drawSize.width) * 0.5, accuracy: 0.5)
        XCTAssertEqual(point.position.y, Float(drawSize.height) * 0.5, accuracy: 0.5)
    }

    func testGlobeBackPointHiddenWithZeroAlpha() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: 1.0))
        XCTAssertEqual(environment.constants.mode, .globe)

        let point = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: -10.0, longitude: -160.0)),
            constants: environment.constants)

        XCTAssertEqual(point.visible, 0)
        XCTAssertEqual(point.visibilityAlpha, 0.0)
    }

    /// Within the horizon band, alpha must pass through intermediate values
    /// rather than switching as a step.
    func testGlobeHorizonFadeBandProducesPartialAlpha() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: 1.0))
        XCTAssertEqual(environment.constants.mode, .globe)

        var foundPartialAlpha = false
        for longitude in stride(from: 30.0, through: 150.0, by: 0.25) {
            let point = GeoScreenProjectionMath.project(
                basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0.0, longitude: longitude)),
                constants: environment.constants)
            if point.visible != 0, point.visibilityAlpha > 0.0, point.visibilityAlpha < 1.0 {
                foundPartialAlpha = true
                break
            }
        }
        XCTAssertTrue(foundPartialAlpha,
                      "Expected a longitude with partial alpha inside the horizon band")
    }

    /// Mid-morph, a point must ride the unfurl wave (transitionLocalPhase)
    /// rather than a uniform lerp of the global transition.
    func testMidMorphAppliesTheUnrollInsteadOfUniformLerp() throws {
        let midMorphZoom = presentationSettings.automaticTransitionStartZoom
            + presentationSettings.automaticTransitionSpan * 0.45
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: midMorphZoom))
        XCTAssertEqual(environment.constants.mode, .globe)
        let transition = environment.constants.globe.transition
        XCTAssertGreaterThan(transition, 0.0)
        XCTAssertLessThan(transition, 0.95)

        let basis = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 25.0, longitude: 35.0))
        let point = GeoScreenProjectionMath.project(basis: basis,
                                                    constants: environment.constants)
        XCTAssertNotEqual(point.visible, 0)

        let sphere = environment.constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit)
        let flat = environment.constants.globeFlatWorldPosition(basis: basis)

        // An independent copy of the unroll from GlobeUnroll.h: a straight
        // chart line between the point's azimuthal-equidistant image and
        // its Mercator image, wrapped onto the growing sphere; not the
        // straight lerp of the two world positions.
        let radius = environment.constants.globe.radius
        let curvature = (1.0 - transition) / radius
        let fromCenter = sphere - SIMD3<Float>(0, 0, -radius)
        let arcSphere = radius * acos(simd_clamp(fromCenter.z / radius, -1.0, 1.0))
        let dirSphere = simd_normalize(SIMD2<Float>(fromCenter.x, fromCenter.y))
        let flat2 = SIMD2<Float>(flat.x, flat.y)
        let chart = dirSphere * arcSphere + (flat2 - dirSphere * arcSphere) * transition
        let arc = simd_length(chart)
        let azimuth = chart / arc
        let angle = arc * curvature
        let unrolled = SIMD3<Float>(azimuth.x * sin(angle) / curvature,
                                    azimuth.y * sin(angle) / curvature,
                                    (cos(angle) - 1.0) / curvature)
        let lerp = sphere + (flat - sphere) * transition
        XCTAssertGreaterThan(simd_length(unrolled - lerp), 1e-2,
                             "Far from the centre the unroll must differ from a uniform lerp")

        let expected = try XCTUnwrap(screenPoint(worldPosition: unrolled,
                                                 constants: environment.constants))
        XCTAssertEqual(point.position.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(point.position.y, expected.y, accuracy: 0.01)

        let uniformWorld = sphere + (flat - sphere) * transition
        let uniformExpected = try XCTUnwrap(screenPoint(worldPosition: uniformWorld,
                                                        constants: environment.constants))
        let distanceToUniform = simd_length(point.position - uniformExpected)
        XCTAssertGreaterThan(distanceToUniform, 1.0,
                             "A uniform lerp must land on a noticeably different screen point")
    }

    /// Regression of a screenshot artifact: mid-morph (medium zoom), a marker
    /// on the far side of the sphere (Fiji with the camera over Voronezh) must
    /// not leak through the globally relaxed horizon threshold: the unfurl wave
    /// has not reached it yet, the point is still spherical.
    func testMidMorphKeepsFarSideMarkerHiddenUntilWaveArrives() throws {
        let midMorphZoom = presentationSettings.automaticTransitionStartZoom
            + presentationSettings.automaticTransitionSpan * 0.37
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 51.209, longitude: 39.205, zoom: midMorphZoom))
        XCTAssertEqual(environment.constants.mode, .globe)
        XCTAssertGreaterThan(environment.constants.globe.transition, 0.0)
        XCTAssertLessThan(environment.constants.globe.transition, 0.95)

        let point = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: -17.7134, longitude: 179.2)),
            constants: environment.constants)

        XCTAssertEqual(point.visible, 0,
                       "A point on the still spherical far side must be hidden")
        XCTAssertEqual(point.visibilityAlpha, 0.0)
    }

    /// Regression of "fly-through" markers: in the morph tail the local phase
    /// of a far point is already ~1 (its position has left the sphere for its
    /// flat location and can cross the viewport on the way), but the global
    /// transition is still < 0.95. A point beyond the SPHERE's horizon must
    /// stay hidden throughout the morph: London with the camera over Tokyo
    /// must not flash over empty ocean.
    func testLateMorphKeepsFarMarkerHiddenDuringUnfurlTransit() throws {
        let tokyoLatitude = 35.6595
        let latitudeExtension = log2(1.0 / cos(tokyoLatitude * .pi / 180.0))
        let lateMorphZoom = presentationSettings.automaticTransitionStartZoom
            + (presentationSettings.automaticTransitionSpan + latitudeExtension) * 0.79
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: tokyoLatitude,
                                         longitude: 139.7005,
                                         zoom: lateMorphZoom,
                                         pitch: 1.28))
        XCTAssertEqual(environment.constants.mode, .globe)
        XCTAssertGreaterThan(environment.constants.globe.transition, 0.8)
        XCTAssertLessThan(environment.constants.globe.transition, 0.95)

        let london = GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 51.5072,
                                                                  longitude: -0.1276))
        let point = GeoScreenProjectionMath.project(basis: london,
                                                    constants: environment.constants)

        XCTAssertEqual(point.visible, 0)
        XCTAssertEqual(point.visibilityAlpha, 0.0)
    }

    /// With the morph nearly complete (geometry already flat, surface still
    /// globe) the former far side is legitimately visible. Camera on the
    /// equator: at latitude the morph window stretches by log2(1/cos(lat)),
    /// and the phase fraction would be computed from a different span.
    func testNearFlatMorphShowsFormerFarSideMarker() throws {
        let nearFlatZoom = presentationSettings.automaticTransitionStartZoom
            + presentationSettings.automaticTransitionSpan * 0.92
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 39.205, zoom: nearFlatZoom))
        XCTAssertEqual(environment.constants.mode, .globe)
        XCTAssertGreaterThanOrEqual(environment.constants.globe.transition, 0.95)

        let point = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: -17.7134, longitude: 179.2)),
            constants: environment.constants)

        XCTAssertNotEqual(point.visible, 0)
        XCTAssertEqual(point.visibilityAlpha, 1.0)
    }

    // MARK: - Helpers

    private struct Environment {
        let presentation: ResolvedPresentationState
        let constants: GeoScreenProjectionMath.FrameConstants
    }

    private func makeEnvironment(cameraState: ImmersiveMapCameraState) throws -> Environment {
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: presentationSettings)
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: Float(drawSize.width / drawSize.height))
        let poseResolver = RenderCameraPoseResolver()
        poseResolver.updateIfNeeded(camera: camera, cameraState: cameraState)
        let cameraMatrix = try XCTUnwrap(camera.cameraMatrix)
        let cameraUniform = CameraUniform(matrix: cameraMatrix,
                                          eye: camera.eye,
                                          padding: 0)
        return Environment(
            presentation: presentation,
            constants: GeoScreenProjectionMath.FrameConstants(drawSize: drawSize,
                                                              cameraUniform: cameraUniform,
                                                              resolvedPresentation: presentation))
    }

    private func makeCameraState(latitude: Double,
                                 longitude: Double,
                                 zoom: Double,
                                 bearing: Float = 0,
                                 pitch: Float = 0) -> ImmersiveMapCameraState {
        let center = ImmersiveMapProjection.worldMercator(latitude: latitude * .pi / 180.0,
                                                          longitude: longitude * .pi / 180.0)
        return ImmersiveMapCameraState(centerWorldMercator: center,
                                       zoom: zoom,
                                       bearing: bearing,
                                       pitch: pitch)
    }

    /// Screen point of a world position through the same camera as FrameConstants
    /// (drawable px, origin bottom-left).
    private func screenPoint(worldPosition: SIMD3<Float>,
                             constants: GeoScreenProjectionMath.FrameConstants) -> SIMD2<Float>? {
        let clip = constants.cameraUniform.matrix * SIMD4<Float>(worldPosition, 1.0)
        guard clip.w > 0 else {
            return nil
        }
        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        return (ndc * 0.5 + 0.5) * constants.viewport
    }
}
