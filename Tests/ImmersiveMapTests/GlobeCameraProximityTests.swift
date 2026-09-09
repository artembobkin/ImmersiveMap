// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
@testable import ImmersiveMap
import simd
import XCTest

/// The globe camera proximity: from the activation zoom up the render
/// camera moves in by the view centre's surface scale, so the frustum
/// holds the same number of tiles at every latitude and the globe shows
/// the Mercator scale of the plane; the pan compensation and the zoom
/// anchor read the same factor, and the surface scale curve is the one
/// the unroll geometry actually has.
final class GlobeCameraProximityTests: XCTestCase {
    private let sixtyDegrees = 60.0 * Double.pi / 180.0

    func testTheMoveInRampsInFromTheActivationZoom() {
        XCTAssertEqual(GlobeCameraProximity.activation(zoom: 0), 0)
        XCTAssertEqual(GlobeCameraProximity.activation(zoom: GlobeCameraProximity.activationZoom), 0)
        XCTAssertEqual(GlobeCameraProximity.activation(zoom: GlobeCameraProximity.activationZoom + GlobeCameraProximity.activationSpan / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GlobeCameraProximity.activation(zoom: GlobeCameraProximity.activationZoom + GlobeCameraProximity.activationSpan), 1)
        XCTAssertEqual(GlobeCameraProximity.activation(zoom: 16), 1)
        XCTAssertEqual(GlobeCameraProximity.activationZoom, 3)
    }

    func testTheFactorIsTheSurfaceScaleOnceActive() {
        XCTAssertEqual(GlobeCameraProximity.distanceFactor(latitude: sixtyDegrees, transition: 0, zoom: 5), 0.5, accuracy: 1e-6,
                       "At 60 degrees on the sphere the camera sits at half the distance")
        XCTAssertEqual(GlobeCameraProximity.distanceFactor(latitude: 0, transition: 0, zoom: 5), 1, accuracy: 1e-6,
                       "The equator is the Mercator scale already")
        XCTAssertEqual(GlobeCameraProximity.distanceFactor(latitude: sixtyDegrees, transition: 1, zoom: 8), 1, accuracy: 1e-6,
                       "The plane needs no move-in")
        XCTAssertEqual(GlobeCameraProximity.distanceFactor(latitude: sixtyDegrees, transition: 0, zoom: 2), 1, accuracy: 1e-6,
                       "Below the activation zoom the camera stays where the zoom puts it")
        XCTAssertEqual(GlobeCameraProximity.distanceFactor(latitude: sixtyDegrees, transition: 0, zoom: 3.5), 0.75, accuracy: 1e-6,
                       "Half way through the ramp, half the move-in")
    }

    func testTheMercatorLimitBoundsTheMoveIn() {
        // The view centre never lies beyond the Mercator limit, so the
        // factor never falls below its cosine and the camera never reaches
        // the surface (the near plane is 0.01 of a unit camera distance).
        let limit = ImmersiveMapProjection.latitude(fromNormalizedWorldY: 0)
        let factor = GlobeCameraProximity.distanceFactor(latitude: limit, transition: 0, zoom: 10)
        XCTAssertEqual(factor, cos(ImmersiveMapProjection.maxMercatorLatitude), accuracy: 1e-6)
        XCTAssertGreaterThan(factor * 0.5, 0.01)
    }

    /// The surface scale curve through the morph is the geometry's: the
    /// unroll blends the azimuthal-equidistant chart with the inflating
    /// flat target, and at the view centre that gives `cos + g^2 (1 - cos)`.
    /// Measured on the CPU mirror of the geometry, for several latitudes and
    /// phases, as the ratio of the surface distance to the Mercator distance
    /// between the centre and a point just north of it.
    func testTheSurfaceScaleCurveMatchesTheUnrollGeometry() {
        for latitudeDegrees in [0.0, 40.0, 70.0, 80.0] {
            for transition in [Float(0), 0.2, 0.45, 0.7, 0.9, 1.0] {
                let latitude = latitudeDegrees * .pi / 180
                let centerY = (1.0 - ImmersiveMapProjection.yMercatorNormalized(latitude: latitude)) * 0.5
                let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, centerY), zoom: 6.5, bearing: 0, pitch: 0)
                var presentation = PresentationStateResolver.resolve(cameraState: cameraState, renderSurfaceMode: .spherical)
                let globe = GlobeUniform(panX: presentation.globeRenderUniform.panX,
                                         panY: presentation.globeRenderUniform.panY,
                                         radius: presentation.globeRenderUniform.radius,
                                         transition: PresentationStateResolver.geometryTransition(transition))
                presentation = ResolvedPresentationState(semanticWorldState: presentation.semanticWorldState,
                                                         presentationState: ImmersiveMapPresentationState(transition: transition),
                                                         renderNormalizationState: presentation.renderNormalizationState,
                                                         renderSurfaceMode: .spherical,
                                                         screenSpaceProjectionMode: .globe,
                                                         globeRenderState: GlobeRenderState(pan: presentation.globeRenderState.pan,
                                                                                            renderRadius: presentation.globeRenderState.renderRadius,
                                                                                            globeUniform: globe),
                                                         flatRenderState: presentation.flatRenderState)
                let constants = GeoScreenProjectionMath.FrameConstants(drawSize: CGSize(width: 100, height: 100),
                                                                       cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: SIMD3<Float>(0, 0, 1), padding: 0),
                                                                       resolvedPresentation: presentation)
                // Half a degree, symmetric about the centre: wide enough for
                // the Float32 mirror's acos near 1, narrow enough that the
                // Mercator stretch across it averages to the centre's.
                let deltaLatitude = 0.5 * .pi / 180
                let center = GeoProjectionBasis(latitudeRadians: latitude - deltaLatitude / 2, longitudeRadians: 0)
                let north = GeoProjectionBasis(latitudeRadians: latitude + deltaLatitude / 2, longitudeRadians: 0)
                func surfacePoint(_ basis: GeoProjectionBasis) -> SIMD3<Float> {
                    let flat = constants.globeFlatWorldPosition(basis: basis)
                    return GlobeUnrollMath.worldPosition(sphereWorldPosition: constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit),
                                                         flatWorldPosition: SIMD2<Float>(flat.x, flat.y),
                                                         transition: globe.transition,
                                                         radius: globe.radius)
                }
                let surfaceDistance = Double(simd_length(surfacePoint(north) - surfacePoint(center)))
                let mercatorDistance = (north.mercatorYNormalized - center.mercatorYNormalized) * 0.5
                    * 2.0 * Double.pi * Double(globe.radius)
                let measured = surfaceDistance / mercatorDistance
                let predicted = SurfaceScaleMath.surfaceScale(latitude: latitude, transition: transition)
                XCTAssertEqual(measured, predicted, accuracy: 0.02,
                               "latitude \(latitudeDegrees) transition \(transition): measured \(measured), predicted \(predicted)")
            }
        }
    }

    func testTheRenderCameraMovesInOnTheGlobe() {
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: 1)
        let resolver = RenderCameraPoseResolver()
        let centerY = (1.0 - ImmersiveMapProjection.yMercatorNormalized(latitude: sixtyDegrees)) * 0.5
        let state = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, centerY), zoom: 5, bearing: 0, pitch: 0)
        resolver.updateIfNeeded(camera: camera, cameraState: state, transition: 0)
        XCTAssertEqual(simd_length(camera.eye), 0.5, accuracy: 1e-5, "Zoom 5 at 60 degrees on the sphere: half the unit distance")
        // The same state on the plane (a forced surface): the phase alone
        // re-poses the camera.
        resolver.updateIfNeeded(camera: camera, cameraState: state, transition: 1)
        XCTAssertEqual(simd_length(camera.eye), 1, accuracy: 1e-5)
        // Below the activation zoom the equatorial distance holds.
        resolver.requestUpdate()
        resolver.updateIfNeeded(camera: camera, cameraState: ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, centerY), zoom: 2, bearing: 0, pitch: 0), transition: 0)
        XCTAssertEqual(simd_length(camera.eye), 1, accuracy: 1e-5)
    }

    func testTheTransitionWindowNoLongerStretchesWithLatitude() {
        let settings = ImmersiveMapSettings.default.presentation
        let from = settings.automaticTransitionStartZoom
        let polarY = (1.0 - ImmersiveMapProjection.yMercatorNormalized(latitude: 80 * .pi / 180)) * 0.5
        let equator = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5), zoom: from + settings.automaticTransitionSpan, bearing: 0, pitch: 0)
        let polar = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, polarY), zoom: from + settings.automaticTransitionSpan, bearing: 0, pitch: 0)
        XCTAssertEqual(PresentationStateResolver.resolve(cameraState: equator, settings: settings).presentationState.transition, 1)
        XCTAssertEqual(PresentationStateResolver.resolve(cameraState: polar, settings: settings).presentationState.transition, 1,
                       "One span above the start the morph is complete at every latitude")
    }

    func testThePanCompensationVanishesOnceTheCameraMovedIn() {
        // At 60 degrees, zoom 8 on the sphere: the camera is at half
        // distance, so a swipe moves the same Mercator as on the plane and
        // the vertical compensation is 1. At zoom 2 (no move-in) it is the
        // old 1 / cos = 2.
        let controller = CameraStateController(settings: ImmersiveMapSettings.default.camera)
        let centerY = (1.0 - ImmersiveMapProjection.yMercatorNormalized(latitude: sixtyDegrees)) * 0.5
        func verticalMove(zoom: Double) -> Double {
            controller.setCameraState(ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, centerY), zoom: zoom, bearing: 0, pitch: 0))
            let before = controller.cameraState.centerWorldMercator.y
            controller.pan(deltaX: 0, deltaY: 10, transition: 0)
            return (controller.cameraState.centerWorldMercator.y - before) * pow(2.0, zoom)
        }
        let equatorController = CameraStateController(settings: ImmersiveMapSettings.default.camera)
        equatorController.setCameraState(ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5), zoom: 8, bearing: 0, pitch: 0))
        let equatorBefore = equatorController.cameraState.centerWorldMercator.y
        equatorController.pan(deltaX: 0, deltaY: 10, transition: 0)
        let equatorMove = (equatorController.cameraState.centerWorldMercator.y - equatorBefore) * pow(2.0, 8)
        XCTAssertEqual(verticalMove(zoom: 8), equatorMove, accuracy: abs(equatorMove) * 1e-6)
        XCTAssertEqual(verticalMove(zoom: 2), equatorMove * 2, accuracy: abs(equatorMove) * 1e-6)
    }
}
