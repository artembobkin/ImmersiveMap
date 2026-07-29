// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// GeoScreenProjectionMath должен проецировать координату теми же формулами,
/// что вершинный путь рендера: flat-мир, сфера глобуса, волна морфа и мягкий
/// горизонт. Камера собирается как в рендере (RenderCamera + PoseResolver),
/// прецедент: ZoomAnchorMathTests.projectToScreen.
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

    /// Маркер по другую сторону антимеридиана от камеры должен через wrap
    /// оказаться рядом с центром экрана, а не на другом конце мира.
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

        // Эквивалентная «неразвёрнутая» долгота обязана дать ту же точку.
        let unwrapped = GeoScreenProjectionMath.project(
            basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 0.0, longitude: 180.1)),
            constants: environment.constants)
        XCTAssertNotEqual(unwrapped.visible, 0)
        XCTAssertEqual(point.position.x, unwrapped.position.x, accuracy: 0.01)
        XCTAssertEqual(point.position.y, unwrapped.position.y, accuracy: 0.01)
    }

    /// Точка плоскости далеко позади наклонённой камеры даёт clip.w <= 0
    /// и должна помечаться невидимой.
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
                      "Ожидалась хотя бы одна точка позади камеры с clip.w <= 0")
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

    /// В полосе горизонта alpha должна проходить промежуточные значения,
    /// а не переключаться ступенькой.
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
                      "Ожидалась долгота с частичной alpha в полосе горизонта")
    }

    /// В середине морфа точка обязана ехать по волне разворота
    /// (transitionLocalPhase), а не по равномерному лерпу global transition.
    func testMidMorphAppliesUnfurlWaveInsteadOfUniformLerp() throws {
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
        let frontDot = (sphere.z + environment.constants.globe.radius) / environment.constants.globe.radius

        // Независимая копия волны из GlobeTransitionProjection.h.
        let spread: Float = 0.6
        let lagWeight = acos(simd_clamp(frontDot, -1.0, 1.0)) / Float.pi
        let localPhase = simd_clamp((transition - lagWeight * spread) / (1.0 - spread), 0.0, 1.0)
        XCTAssertGreaterThan(abs(localPhase - transition), 1e-3,
                             "Для точки вдали от центра волна должна отличаться от равномерного лерпа")

        let waveWorld = sphere + (flat - sphere) * localPhase
        let expected = try XCTUnwrap(screenPoint(worldPosition: waveWorld,
                                                 constants: environment.constants))
        XCTAssertEqual(point.position.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(point.position.y, expected.y, accuracy: 0.01)

        let uniformWorld = sphere + (flat - sphere) * transition
        let uniformExpected = try XCTUnwrap(screenPoint(worldPosition: uniformWorld,
                                                        constants: environment.constants))
        let distanceToUniform = simd_length(point.position - uniformExpected)
        XCTAssertGreaterThan(distanceToUniform, 1.0,
                             "Равномерный лерп должен давать заметно другую экранную точку")
    }

    // MARK: - Хелперы

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

    /// Экранная точка мировой позиции той же камерой, что у FrameConstants
    /// (drawable px, origin снизу слева).
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
