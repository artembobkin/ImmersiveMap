// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd

struct CameraFrameState {
    let drawSize: CGSize
    let viewport: SIMD2<Float>
    let cameraMatrices: FrameCameraMatrices
    let cameraEye: SIMD3<Float>
    let cameraFrustum: Frustum?
    let mapCameraState: ImmersiveMapCameraState
    let qualityTier: RenderQualityTier
}

/// Отвечает за подготовку состояния камеры для кадра рендера:
/// синхронизирует управляющую камеру с render-камерой, применяет ограничения
/// и собирает матрицы, frustum, eye position и camera state для frame pipeline.
final class FrameCameraStateResolver {
    private let camera: RenderCamera
    private let cameraStateController: CameraStateController
    private let cameraPoseResolver: RenderCameraPoseResolver
    private let screenMatrix: ScreenMatrix
    private var lastDrawableSize: CGSize = .zero

    init(settings: ImmersiveMapSettings) {
        self.camera = RenderCamera()
        self.cameraStateController = CameraStateController(settings: settings.camera)
        self.cameraPoseResolver = RenderCameraPoseResolver()
        self.screenMatrix = ScreenMatrix()
        RendererSetup.configureCamera(cameraStateController)
        requestRenderCameraUpdate()
    }

    func makeFrameState(drawSize: CGSize, diagnostics: FrameDiagnostics) -> CameraFrameState? {
        guard drawSize.width > 0, drawSize.height > 0 else {
            diagnostics.recordSkipReason(.zeroDrawableSize)
            return nil
        }

        if drawSize != lastDrawableSize {
            let aspect = Float(drawSize.width) / Float(drawSize.height)
            camera.recalculateProjection(aspect: aspect)
            lastDrawableSize = drawSize
        }

        screenMatrix.update(drawSize)
        guard let screenMatrixValue = screenMatrix.get() else {
            diagnostics.recordSkipReason(.missingScreenMatrix)
            return nil
        }

        cameraPoseResolver.updateIfNeeded(camera: camera, cameraState: cameraStateController.cameraState)
        guard let cameraMatrix = camera.cameraMatrix,
              let cameraView = camera.view else {
            diagnostics.recordSkipReason(.missingCameraState)
            return nil
        }

        let matrices = FrameCameraMatrices(projectionView: cameraMatrix,
                                           view: cameraView,
                                           screen: screenMatrixValue)

        return CameraFrameState(drawSize: drawSize,
                                viewport: SIMD2<Float>(Float(drawSize.width), Float(drawSize.height)),
                                cameraMatrices: matrices,
                                cameraEye: camera.eye,
                                cameraFrustum: camera.frustrum,
                                mapCameraState: cameraStateController.cameraState,
                                qualityTier: RenderQualityTier.from(zoom: cameraStateController.zoom))
    }

    func rotateCameraYaw(delta: Float) {
        cameraStateController.rotateYaw(delta: delta)
        requestRenderCameraUpdate()
    }

    func panCamera(deltaX: Double, deltaY: Double) {
        cameraStateController.pan(deltaX: deltaX, deltaY: deltaY)
        requestRenderCameraUpdate()
    }

    func zoomCamera(scale: Double, velocity: Double = 0) {
        cameraStateController.zoom(scale: scale, velocity: velocity)
        requestRenderCameraUpdate()
    }

    func zoomCamera(delta: Double) {
        cameraStateController.zoom(delta: delta)
        requestRenderCameraUpdate()
    }

    func setCameraPitch(_ pitch: Float) {
        cameraStateController.setPitch(pitch)
        requestRenderCameraUpdate()
    }

    func setCameraBearing(_ bearing: Float) {
        cameraStateController.setBearing(bearing)
        requestRenderCameraUpdate()
    }

    func setCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition) {
        cameraStateController.setCameraPosition(cameraPosition)
        requestRenderCameraUpdate()
    }

    func setCameraState(_ cameraState: ImmersiveMapCameraState) {
        cameraStateController.setCameraState(cameraState)
        requestRenderCameraUpdate()
    }

    func currentCameraPosition() -> ImmersiveMapCameraPosition {
        let latLon = cameraStateController.getLatLonDeg()
        return ImmersiveMapCameraPosition(latitudeDegrees: latLon.latDeg,
                                          longitudeDegrees: latLon.lonDeg,
                                          zoom: cameraStateController.zoom,
                                          bearing: cameraStateController.yaw,
                                          pitch: cameraStateController.pitch)
    }

    func currentCameraState() -> ImmersiveMapCameraState {
        cameraStateController.currentCameraState()
    }

    func applyCameraSettings(_ settings: ImmersiveMapSettings.CameraSettings) {
        cameraStateController.apply(settings: settings)
        requestRenderCameraUpdate()
    }

    func applyConstraints(_ constraints: CameraConstraints) {
        cameraStateController.clampBearing(to: constraints.bearing)
        cameraStateController.clampPitch(to: constraints.pitch)
        requestRenderCameraUpdate()
    }

    private func requestRenderCameraUpdate() {
        cameraPoseResolver.requestUpdate()
    }
}
