// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import simd
import XCTest

/// Anchored zoom должен держать мировую точку под курсором на месте: проверяем
/// инвариант полной рендер-проекцией (PresentationStateResolver + RenderCamera)
/// до и после компенсации центра из `ZoomAnchorMath`.
final class ZoomAnchorMathTests: XCTestCase {
    private let viewport = CGSize(width: 800, height: 600)
    private let presentationSettings = ImmersiveMapSettings.default.presentation

    func testFlatAnchoredZoomKeepsPointUnderCursor() throws {
        try assertFlatAnchorInvariant(zoomBefore: 15.3,
                                      zoomAfter: 15.9,
                                      bearing: 0)
    }

    func testFlatAnchoredZoomAcrossIntegerZoomBoundary() throws {
        try assertFlatAnchorInvariant(zoomBefore: 15.8,
                                      zoomAfter: 16.4,
                                      bearing: 0)
    }

    func testFlatAnchoredZoomWithBearing() throws {
        try assertFlatAnchorInvariant(zoomBefore: 15.3,
                                      zoomAfter: 15.9,
                                      bearing: 0.7)
    }

    func testFlatAnchoredZoomOutKeepsPointUnderCursor() throws {
        try assertFlatAnchorInvariant(zoomBefore: 15.5,
                                      zoomAfter: 14.8,
                                      bearing: 0)
    }

    func testGlobeAnchoredZoomKeepsPointNearCursor() throws {
        let stateBefore = makeCameraState(latitude: 10.0,
                                          longitude: 20.0,
                                          zoom: 2.0)
        var stateAfter = stateBefore
        stateAfter.zoom = 2.6

        // Точка недалеко от центра экрана: линейное приближение сферы точное
        // только вблизи центра.
        let pointLatitude = 12.0
        let pointLongitude = 23.0
        let anchor = try XCTUnwrap(projectToScreen(latitude: pointLatitude,
                                                   longitude: pointLongitude,
                                                   cameraState: stateBefore))

        stateAfter.centerWorldMercator = compensatedCenter(stateBefore: stateBefore,
                                                           stateAfter: stateAfter,
                                                           anchorPoint: anchor)
        let projected = try XCTUnwrap(projectToScreen(latitude: pointLatitude,
                                                      longitude: pointLongitude,
                                                      cameraState: stateAfter))

        XCTAssertEqual(Double(projected.x), Double(anchor.x), accuracy: 4.0)
        XCTAssertEqual(Double(projected.y), Double(anchor.y), accuracy: 4.0)
    }

    func testAnchorFactorZeroKeepsCenter() {
        let stateBefore = makeCameraState(latitude: 55.75,
                                          longitude: 37.61,
                                          zoom: 15.0)
        var stateAfter = stateBefore
        stateAfter.zoom = 16.0

        let center = compensatedCenter(stateBefore: stateBefore,
                                       stateAfter: stateAfter,
                                       anchorPoint: CGPoint(x: 600, y: 150),
                                       anchorFactor: 0.0)

        XCTAssertEqual(center, stateBefore.centerWorldMercator)
    }

    func testCenterAnchorKeepsCenter() {
        let stateBefore = makeCameraState(latitude: 55.75,
                                          longitude: 37.61,
                                          zoom: 15.0)
        var stateAfter = stateBefore
        stateAfter.zoom = 16.0

        let center = compensatedCenter(stateBefore: stateBefore,
                                       stateAfter: stateAfter,
                                       anchorPoint: CGPoint(x: viewport.width * 0.5,
                                                            y: viewport.height * 0.5))

        XCTAssertEqual(center, stateBefore.centerWorldMercator)
    }

    func testEqualZoomsKeepCenter() {
        let state = makeCameraState(latitude: 55.75,
                                    longitude: 37.61,
                                    zoom: 20.0)

        let center = compensatedCenter(stateBefore: state,
                                       stateAfter: state,
                                       anchorPoint: CGPoint(x: 600, y: 150))

        XCTAssertEqual(center, state.centerWorldMercator)
    }

    // MARK: - Хелперы

    /// Инвариант для плоской фазы: гео-точка, спроецированная в anchor до зума,
    /// после anchored-зума проецируется в ту же экранную точку.
    private func assertFlatAnchorInvariant(zoomBefore: Double,
                                           zoomAfter: Double,
                                           bearing: Float,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws {
        let stateBefore = makeCameraState(latitude: 55.7558,
                                          longitude: 37.6173,
                                          zoom: zoomBefore,
                                          bearing: bearing)
        var stateAfter = stateBefore
        stateAfter.zoom = zoomAfter

        let pointLatitude = 55.7625
        let pointLongitude = 37.6300
        let anchor = try XCTUnwrap(projectToScreen(latitude: pointLatitude,
                                                   longitude: pointLongitude,
                                                   cameraState: stateBefore),
                                   file: file,
                                   line: line)

        stateAfter.centerWorldMercator = compensatedCenter(stateBefore: stateBefore,
                                                           stateAfter: stateAfter,
                                                           anchorPoint: anchor)
        let projected = try XCTUnwrap(projectToScreen(latitude: pointLatitude,
                                                      longitude: pointLongitude,
                                                      cameraState: stateAfter),
                                      file: file,
                                      line: line)

        XCTAssertEqual(Double(projected.x), Double(anchor.x), accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(Double(projected.y), Double(anchor.y), accuracy: 0.5, file: file, line: line)
    }

    private func compensatedCenter(stateBefore: ImmersiveMapCameraState,
                                   stateAfter: ImmersiveMapCameraState,
                                   anchorPoint: CGPoint,
                                   anchorFactor: Double = 1.0) -> SIMD2<Double> {
        let transitionBefore = PresentationStateResolver.resolve(cameraState: stateBefore,
                                                                 settings: presentationSettings).presentationState.transition
        let transitionAfter = PresentationStateResolver.resolve(cameraState: stateAfter,
                                                                settings: presentationSettings).presentationState.transition
        return ZoomAnchorMath.compensatedCenterWorldMercator(
            ZoomAnchorMath.Input(anchorPoint: anchorPoint,
                                 viewportSize: viewport,
                                 centerWorldMercator: stateBefore.centerWorldMercator,
                                 zoomBefore: stateBefore.zoom,
                                 zoomAfter: stateAfter.zoom,
                                 bearing: stateBefore.bearing,
                                 transitionBefore: transitionBefore,
                                 transitionAfter: transitionAfter,
                                 globeRadiusScale: presentationSettings.globeRadiusScale,
                                 anchorFactor: anchorFactor)
        )
    }

    private func makeCameraState(latitude: Double,
                                 longitude: Double,
                                 zoom: Double,
                                 bearing: Float = 0) -> ImmersiveMapCameraState {
        let center = ImmersiveMapProjection.worldMercator(latitude: latitude * .pi / 180.0,
                                                          longitude: longitude * .pi / 180.0)
        return ImmersiveMapCameraState(centerWorldMercator: center,
                                       zoom: zoom,
                                       bearing: bearing,
                                       pitch: 0)
    }

    /// Проецирует гео-точку в экранные координаты view (top-left origin, points)
    /// теми же формулами, что рендер: flat-мир либо сфера глобуса (transition 0)
    /// + перспективная камера RenderCamera/RenderCameraPoseResolver.
    private func projectToScreen(latitude: Double,
                                 longitude: Double,
                                 cameraState: ImmersiveMapCameraState) -> CGPoint? {
        let presentation = PresentationStateResolver.resolve(cameraState: cameraState,
                                                             settings: presentationSettings)
        let camera = RenderCamera()
        camera.recalculateProjection(aspect: Float(viewport.width / viewport.height))
        let poseResolver = RenderCameraPoseResolver()
        poseResolver.updateIfNeeded(camera: camera, cameraState: cameraState)
        guard let cameraMatrix = camera.cameraMatrix else {
            return nil
        }

        let latitudeRadians = latitude * .pi / 180.0
        let longitudeRadians = longitude * .pi / 180.0
        let worldPosition: SIMD3<Float>
        switch presentation.screenSpaceProjectionMode {
        case .flat:
            let flatPosition = ImmersiveMapProjection.flatWorldPosition(latitude: latitudeRadians,
                                                                        longitude: longitudeRadians,
                                                                        flatRenderPan: presentation.flatRenderState.pan,
                                                                        renderMapSize: presentation.flatRenderState.renderMapSize)
            worldPosition = SIMD3<Float>(flatPosition.x, flatPosition.y, 0)
        case .globe:
            guard presentation.presentationState.transition == 0 else {
                // Морфинг сферы в плоскость в тестовой проекции не воспроизводится.
                return nil
            }
            worldPosition = sphereWorldPosition(latitudeRadians: latitudeRadians,
                                                longitudeRadians: longitudeRadians,
                                                globeRenderState: presentation.globeRenderState)
        }

        let clip = cameraMatrix * SIMD4<Float>(worldPosition, 1)
        guard clip.w > 0 else {
            return nil
        }

        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        return CGPoint(x: (Double(ndc.x) * 0.5 + 0.5) * viewport.width,
                       y: (1.0 - (Double(ndc.y) * 0.5 + 0.5)) * viewport.height)
    }

    /// Сферическая позиция точки глобуса: формулы `GlobeProjectionConstants`
    /// из AvatarSelectionProjector при transition 0.
    private func sphereWorldPosition(latitudeRadians: Double,
                                     longitudeRadians: Double,
                                     globeRenderState: GlobeRenderState) -> SIMD3<Float> {
        let radius = Float(globeRenderState.renderRadius)
        let panLatitude = Float(globeRenderState.pan.y) * Float(ImmersiveMapProjection.maxMercatorLatitude)
        let panLongitude = Float(globeRenderState.pan.x) * Float.pi

        let xRotation = matrix_float4x4(SIMD4<Float>(1, 0, 0, 0),
                                        SIMD4<Float>(0, cos(panLatitude), -sin(panLatitude), 0),
                                        SIMD4<Float>(0, sin(panLatitude), cos(panLatitude), 0),
                                        SIMD4<Float>(0, 0, 0, 1))
        let yRotation = matrix_float4x4(SIMD4<Float>(cos(panLongitude), 0, sin(panLongitude), 0),
                                        SIMD4<Float>(0, 1, 0, 0),
                                        SIMD4<Float>(-sin(panLongitude), 0, cos(panLongitude), 0),
                                        SIMD4<Float>(0, 0, 0, 1))
        let rotation = matrix_multiply(yRotation, xRotation)

        let cosLatitude = cos(latitudeRadians)
        let sphereUnit = SIMD3<Float>(Float(cosLatitude * sin(longitudeRadians)),
                                      Float(sin(latitudeRadians)),
                                      Float(cosLatitude * cos(longitudeRadians)))
        let rotated = simd_transpose(rotation) * SIMD4<Float>(sphereUnit * radius, 1)
        return SIMD3<Float>(rotated.x, rotated.y, rotated.z - radius)
    }
}
