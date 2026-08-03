// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// SceneModelAnchorMath must place a model anchor with the same formulas as
/// GeoScreenProjectionMath (the CPU mirror of the globe shaders): flat world,
/// globe sphere, and the unfurl wave. The camera is assembled as in the
/// renderer, precedent: GeoScreenProjectionMathTests.
final class SceneModelAnchorMathTests: XCTestCase {
    private let drawSize = CGSize(width: 800, height: 600)
    private let presentationSettings = ImmersiveMapSettings.default.presentation
    private let unitBounds = SceneModelMesh.Bounds(center: .zero, radius: 1, maxExtent: 1)

    // MARK: - Position equivalence with the geo projector

    func testFlatAnchorMatchesGeoProjector() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 55.75, longitude: 37.61, zoom: 15.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        for (latitude, longitude) in [(55.75, 37.61), (55.79, 37.55), (55.70, 37.70)] {
            let presented = makePresented(latitude: latitude, longitude: longitude)
            let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                            bounds: unitBounds,
                                                            constants: environment.constants)
            let projected = GeoScreenProjectionMath.project(
                basis: presented.projectionBasis,
                constants: environment.constants)
            let anchorScreen = try XCTUnwrap(screenPoint(worldPosition: translation(of: anchor.modelMatrix),
                                                         constants: environment.constants))

            XCTAssertNotEqual(projected.visible, 0)
            XCTAssertTrue(anchor.passesHorizonGate)
            XCTAssertEqual(anchorScreen.x, projected.position.x, accuracy: 0.01)
            XCTAssertEqual(anchorScreen.y, projected.position.y, accuracy: 0.01)
        }
    }

    func testGlobeAnchorMatchesGeoProjectorAtTransitionZero() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 10.0, longitude: 20.0, zoom: 1.0))
        XCTAssertEqual(environment.constants.mode, .globe)
        XCTAssertEqual(environment.constants.globe.transition, 0.0)

        for (latitude, longitude) in [(10.0, 20.0), (14.0, 26.0), (-3.0, 12.0)] {
            let presented = makePresented(latitude: latitude, longitude: longitude)
            let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                            bounds: unitBounds,
                                                            constants: environment.constants)
            let projected = GeoScreenProjectionMath.project(
                basis: presented.projectionBasis,
                constants: environment.constants)
            let anchorScreen = try XCTUnwrap(screenPoint(worldPosition: translation(of: anchor.modelMatrix),
                                                         constants: environment.constants))

            XCTAssertNotEqual(projected.visible, 0)
            XCTAssertTrue(anchor.passesHorizonGate)
            XCTAssertEqual(anchorScreen.x, projected.position.x, accuracy: 0.01)
            XCTAssertEqual(anchorScreen.y, projected.position.y, accuracy: 0.01)
        }
    }

    func testMidMorphAnchorRidesUnfurlWave() throws {
        let midMorphZoom = presentationSettings.automaticTransitionStartZoom
            + presentationSettings.automaticTransitionSpan * 0.45
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: midMorphZoom))
        XCTAssertEqual(environment.constants.mode, .globe)
        let transition = environment.constants.globe.transition
        XCTAssertGreaterThan(transition, 0.0)
        XCTAssertLessThan(transition, 0.95)

        let presented = makePresented(latitude: 25.0, longitude: 35.0)
        let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                        bounds: unitBounds,
                                                        constants: environment.constants)

        let basis = presented.projectionBasis
        let sphere = environment.constants.rotatedSphereWorldPosition(sphereUnit: basis.sphereUnit)
        let flat = environment.constants.globeFlatWorldPosition(basis: basis)
        let frontDot = (sphere.z + environment.constants.globe.radius) / environment.constants.globe.radius
        let localPhase = GeoScreenProjectionMath.transitionLocalPhase(transition, frontDot: frontDot)
        let waveWorld = sphere + (flat - sphere) * localPhase

        let anchorScreen = try XCTUnwrap(screenPoint(worldPosition: translation(of: anchor.modelMatrix),
                                                     constants: environment.constants))
        let expected = try XCTUnwrap(screenPoint(worldPosition: waveWorld,
                                                 constants: environment.constants))
        XCTAssertEqual(anchorScreen.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(anchorScreen.y, expected.y, accuracy: 0.01)
    }

    // MARK: - Tangent frame

    func testTangentFrameStaysOrthonormalThroughMorph() throws {
        let zooms = [1.0,
                     presentationSettings.automaticTransitionStartZoom + presentationSettings.automaticTransitionSpan * 0.3,
                     presentationSettings.automaticTransitionStartZoom + presentationSettings.automaticTransitionSpan * 0.7,
                     15.0]
        let coordinates = [(0.0, 0.0), (60.0, 170.0), (-45.0, -179.9), (80.0, 10.0)]

        for zoom in zooms {
            let environment = try makeEnvironment(
                cameraState: makeCameraState(latitude: 45.0, longitude: 10.0, zoom: zoom))
            for (latitude, longitude) in coordinates {
                let presented = makePresented(latitude: latitude, longitude: longitude)
                let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                                bounds: unitBounds,
                                                                constants: environment.constants)
                let linear = linearPart(of: anchor.modelMatrix)
                let axisX = simd_normalize(linear.columns.0)
                let axisY = simd_normalize(linear.columns.1)
                let axisZ = simd_normalize(linear.columns.2)

                XCTAssertEqual(simd_dot(axisX, axisY), 0, accuracy: 1e-3)
                XCTAssertEqual(simd_dot(axisY, axisZ), 0, accuracy: 1e-3)
                XCTAssertEqual(simd_dot(axisX, axisZ), 0, accuracy: 1e-3)
                // Uniform scale: all columns share one length.
                let lengthX = simd_length(linear.columns.0)
                XCTAssertEqual(simd_length(linear.columns.1) / lengthX, 1, accuracy: 1e-3)
                XCTAssertEqual(simd_length(linear.columns.2) / lengthX, 1, accuracy: 1e-3)
                // Right-handed: no mirroring anywhere in the composition.
                XCTAssertGreaterThan(simd_dot(simd_cross(axisX, axisY), axisZ), 0.5)
            }
        }
    }

    /// In flat mode with identity orientation, the composition reduces to the
    /// USD Y-up to map Z-up conversion: asset +X stays east, asset +Y becomes
    /// world up, asset +Z faces south.
    func testFlatBasisIsIdentityWithYUpConversion() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 48.85, longitude: 2.35, zoom: 15.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        let presented = makePresented(latitude: 48.85, longitude: 2.35)
        let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                        bounds: unitBounds,
                                                        constants: environment.constants)
        let linear = linearPart(of: anchor.modelMatrix)

        assertDirection(simd_normalize(linear.columns.0), SIMD3<Float>(1, 0, 0))
        assertDirection(simd_normalize(linear.columns.1), SIMD3<Float>(0, 0, 1))
        assertDirection(simd_normalize(linear.columns.2), SIMD3<Float>(0, -1, 0))
    }

    func testHeadingRotatesModelForwardTowardEast() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: 15.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        // Asset -Z faces north at heading 0; heading 90 (clockwise) turns it east.
        let presented = makePresented(latitude: 0.0, longitude: 0.0, headingDegrees: 90.0)
        let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                        bounds: unitBounds,
                                                        constants: environment.constants)
        let linear = linearPart(of: anchor.modelMatrix)
        let forward = simd_normalize(linear * SIMD3<Float>(0, 0, -1))
        assertDirection(forward, SIMD3<Float>(1, 0, 0))
    }

    // MARK: - Meter scale, altitude, fit

    func testFlatMeterScaleMatchesWorldUnitsPerMeter() throws {
        let latitude = 60.0
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: latitude, longitude: 30.0, zoom: 15.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        let presented = makePresented(latitude: latitude, longitude: 30.0)
        let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                        bounds: unitBounds,
                                                        constants: environment.constants)
        let expected = Float(ImmersiveMapProjection.worldUnitsPerMeter(
            latitudeRadians: latitude * .pi / 180.0,
            renderMapSize: environment.presentation.flatRenderState.renderMapSize))
        let scale = simd_length(linearPart(of: anchor.modelMatrix).columns.0)
        XCTAssertEqual(scale / expected, 1, accuracy: 1e-3)
    }

    func testGlobeMeterScaleMatchesSphereCircumference() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 10.0, longitude: 20.0, zoom: 1.0))
        XCTAssertEqual(environment.constants.globe.transition, 0.0)

        // On the sphere the meter scale is latitude-independent true scale.
        for latitude in [0.0, 12.0, 60.0] {
            let presented = makePresented(latitude: latitude, longitude: 20.0)
            let anchor = SceneModelAnchorMath.resolveAnchor(presented: presented,
                                                            bounds: unitBounds,
                                                            constants: environment.constants)
            let expected = 2 * Float.pi * environment.constants.globe.radius
                / Float(ImmersiveMapProjection.earthCircumferenceMeters)
            let scale = simd_length(linearPart(of: anchor.modelMatrix).columns.0)
            XCTAssertEqual(scale / expected, 1, accuracy: 1e-3)
        }
    }

    func testAltitudeLiftsAnchorAlongUpByMeters() throws {
        let latitude = 55.75
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: latitude, longitude: 37.61, zoom: 15.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        let grounded = SceneModelAnchorMath.resolveAnchor(
            presented: makePresented(latitude: latitude, longitude: 37.61),
            bounds: unitBounds,
            constants: environment.constants)
        let lifted = SceneModelAnchorMath.resolveAnchor(
            presented: makePresented(latitude: latitude, longitude: 37.61, altitudeMeters: 100.0),
            bounds: unitBounds,
            constants: environment.constants)

        let unitsPerMeter = Float(ImmersiveMapProjection.worldUnitsPerMeter(
            latitudeRadians: latitude * .pi / 180.0,
            renderMapSize: environment.presentation.flatRenderState.renderMapSize))
        let groundedPosition = translation(of: grounded.modelMatrix)
        let liftedPosition = translation(of: lifted.modelMatrix)
        XCTAssertEqual(liftedPosition.x, groundedPosition.x, accuracy: 1e-6)
        XCTAssertEqual(liftedPosition.y, groundedPosition.y, accuracy: 1e-6)
        XCTAssertEqual((liftedPosition.z - groundedPosition.z) / (100.0 * unitsPerMeter), 1, accuracy: 1e-3)
    }

    func testFitDiameterOverridesNativeSize() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: 15.0))
        let bounds = SceneModelMesh.Bounds(center: .zero, radius: 3.46, maxExtent: 4)

        let native = SceneModelAnchorMath.resolveAnchor(
            presented: makePresented(latitude: 0.0, longitude: 0.0),
            bounds: bounds,
            constants: environment.constants)
        let fitted = SceneModelAnchorMath.resolveAnchor(
            presented: makePresented(latitude: 0.0, longitude: 0.0, fitDiameterMeters: 200.0),
            bounds: bounds,
            constants: environment.constants)

        let nativeScale = simd_length(linearPart(of: native.modelMatrix).columns.0)
        let fittedScale = simd_length(linearPart(of: fitted.modelMatrix).columns.0)
        XCTAssertEqual(fittedScale / nativeScale, 50, accuracy: 0.05)
    }

    // MARK: - Horizon gate and antimeridian

    func testFarSideAnchorFailsHorizonGate() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 0.0, zoom: 1.0))
        XCTAssertEqual(environment.constants.mode, .globe)

        let farSide = SceneModelAnchorMath.resolveAnchor(
            presented: makePresented(latitude: -10.0, longitude: -160.0),
            bounds: unitBounds,
            constants: environment.constants)
        XCTAssertFalse(farSide.passesHorizonGate)

        let front = SceneModelAnchorMath.resolveAnchor(
            presented: makePresented(latitude: 2.0, longitude: 3.0),
            bounds: unitBounds,
            constants: environment.constants)
        XCTAssertTrue(front.passesHorizonGate)
    }

    func testFlatAntimeridianAnchorWrapsNearCamera() throws {
        let environment = try makeEnvironment(
            cameraState: makeCameraState(latitude: 0.0, longitude: 179.9, zoom: 10.0))
        XCTAssertEqual(environment.constants.mode, .flat)

        let anchor = SceneModelAnchorMath.resolveAnchor(
            presented: makePresented(latitude: 0.0, longitude: -179.9),
            bounds: unitBounds,
            constants: environment.constants)
        let projected = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0.0, longitude: -179.9)),
            constants: environment.constants)
        let anchorScreen = try XCTUnwrap(screenPoint(worldPosition: translation(of: anchor.modelMatrix),
                                                     constants: environment.constants))

        XCTAssertNotEqual(projected.visible, 0)
        XCTAssertEqual(anchorScreen.x, projected.position.x, accuracy: 0.01)
        XCTAssertEqual(anchorScreen.y, projected.position.y, accuracy: 0.01)
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

    private func makePresented(latitude: Double,
                               longitude: Double,
                               altitudeMeters: Double = 0,
                               headingDegrees: Double = 0,
                               pitchDegrees: Double = 0,
                               rollDegrees: Double = 0,
                               scale: Double = 1,
                               fitDiameterMeters: Double? = nil) -> PresentedSceneModel {
        PresentedSceneModel(
            id: 1,
            source: ImmersiveMapSceneModel.Source(url: URL(fileURLWithPath: "/tmp/model.usdz")),
            fitDiameterMeters: fitDiameterMeters,
            projectionBasis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: latitude,
                                                                          longitude: longitude)),
            orientation: SceneModelAnimationMath.orientationQuaternion(headingDegrees: headingDegrees,
                                                                       pitchDegrees: pitchDegrees,
                                                                       rollDegrees: rollDegrees),
            scale: scale,
            altitudeMeters: altitudeMeters)
    }

    private func translation(of matrix: matrix_float4x4) -> SIMD3<Float> {
        matrix.columns.3.xyz
    }

    private func linearPart(of matrix: matrix_float4x4) -> simd_float3x3 {
        simd_float3x3(matrix.columns.0.xyz, matrix.columns.1.xyz, matrix.columns.2.xyz)
    }

    private func assertDirection(_ actual: SIMD3<Float>,
                                 _ expected: SIMD3<Float>,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-4, file: file, line: line)
    }

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
