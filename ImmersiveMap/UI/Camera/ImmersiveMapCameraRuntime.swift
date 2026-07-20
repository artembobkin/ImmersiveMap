// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd

/// Владеет mutable camera state одного map view.
/// Оборачивает `FrameCameraStateResolver`, применяет camera changes, хранит settings и запрашивает frames.
@MainActor
final class ImmersiveMapCameraRuntime {
    private let initialCameraPosition: ImmersiveMapCameraPosition?
    let presentationStateResolver: MapPresentationStateController
    private let renderRuntime: ImmersiveMapRenderRuntime
    private let controlsRuntime: ImmersiveMapControlsRuntime
    private let viewportRuntime: ImmersiveMapViewportRuntime
    private weak var controller: ImmersiveMapCameraController?
    private(set) var renderCamera: FrameCameraStateResolver?
    private var settings: ImmersiveMapSettings
    private var appliedCameraPosition: ImmersiveMapCameraPosition?
    private var cameraNotificationGeneration = 0

    init(settings: ImmersiveMapSettings,
         initialCameraPosition: ImmersiveMapCameraPosition?,
         renderRuntime: ImmersiveMapRenderRuntime,
         controlsRuntime: ImmersiveMapControlsRuntime,
         viewportRuntime: ImmersiveMapViewportRuntime) {
        self.settings = settings
        self.initialCameraPosition = initialCameraPosition
        self.presentationStateResolver = MapPresentationStateController(settings: settings)
        self.renderRuntime = renderRuntime
        self.controlsRuntime = controlsRuntime
        self.viewportRuntime = viewportRuntime
    }

    var currentSettings: ImmersiveMapSettings {
        settings
    }

    func isAttachedController(_ cameraController: ImmersiveMapCameraController?) -> Bool {
        controller === cameraController
    }

    func updateSettings(_ settings: ImmersiveMapSettings,
                        notifiesCameraPositionChanged: Bool = true) {
        self.settings = settings
        presentationStateResolver.applySettings(settings)
        renderCamera?.applyCameraSettings(settings.camera)
        applyCurrentCameraConstraints()
        if notifiesCameraPositionChanged {
            notifyCameraPositionChanged()
        }
    }

    @MainActor
    func attachController(_ newController: ImmersiveMapCameraController?,
                          commandHandler: ImmersiveMapCameraCommandHandler) {
        guard controller !== newController else {
            return
        }

        controller?.setCommandHandler(nil)
        controller?.updateCurrentCameraPosition(nil)
        controller?.updateCurrentCameraSnapshot(nil)
        controller = newController
        newController?.setCommandHandler { command in
            commandHandler.handle(command)
        }
        newController?.updateCurrentCameraPosition(currentCameraPosition())
        notifyCameraPositionChanged()
    }

    func detachController() {
        controller?.setCommandHandler(nil)
        controller?.updateCurrentCameraPosition(nil)
        controller?.updateCurrentCameraSnapshot(nil)
        controller = nil
    }

    func makeRenderCamera(settings: ImmersiveMapSettings,
                          cameraPosition: ImmersiveMapCameraPosition?) -> FrameCameraStateResolver {
        self.settings = settings
        let renderCamera = FrameCameraStateResolver(settings: settings)
        self.renderCamera = renderCamera
        if let cameraPosition {
            renderCamera.setCameraPosition(cameraPosition)
            appliedCameraPosition = cameraPosition
        }
        applyCurrentCameraConstraints()
        syncPitchControlValue(fallbackCameraPosition: cameraPosition)
        notifyCameraPositionChanged()
        return renderCamera
    }

    func clearRenderCamera() {
        renderCamera = nil
    }

    func cameraPositionForRendererRecreation() -> ImmersiveMapCameraPosition? {
        currentCameraPosition()
    }

    func currentCameraPosition() -> ImmersiveMapCameraPosition? {
        renderCamera?.currentCameraPosition()
            ?? appliedCameraPosition
            ?? initialCameraPosition
    }

    func currentCameraState() -> ImmersiveMapCameraState? {
        renderCamera?.currentCameraState()
    }

    var currentPitch: Float? {
        renderCamera?.currentCameraState().pitch
    }

    var currentBearing: Float? {
        renderCamera?.currentCameraState().bearing
    }

    func currentMaximumAbsoluteBearing() -> Float {
        guard let cameraState = renderCamera?.currentCameraState() else {
            return .pi
        }

        return currentCameraConstraints(cameraState: cameraState).bearing.maximumAbsoluteBearing ?? .pi
    }

    func currentCameraSnapshot(position overridePosition: ImmersiveMapCameraPosition? = nil) -> ImmersiveMapCameraSnapshot? {
        guard let renderCamera else {
            return nil
        }

        let cameraState = renderCamera.currentCameraState()
        let position = overridePosition ?? renderCamera.currentCameraPosition()
        let constraints = currentCameraConstraints(cameraState: cameraState)
        return ImmersiveMapCameraSnapshotResolver.resolve(
            position: position,
            constraints: constraints,
            isSphericalSurfaceActive: presentationStateResolver.isSphericalSurfaceActive(cameraState: cameraState)
        )
    }

    func currentMaximumPitch() -> Float {
        guard let cameraState = renderCamera?.currentCameraState() else {
            return settings.camera.maximumPitch
        }

        return currentCameraConstraints(cameraState: cameraState).pitch.maximumPitch
    }

    func isSphericalRenderSurfaceActive() -> Bool {
        guard let cameraState = renderCamera?.currentCameraState() else {
            return false
        }

        return presentationStateResolver.isSphericalSurfaceActive(cameraState: cameraState)
    }

    func needsCameraPositionUpdate(_ cameraPosition: ImmersiveMapCameraPosition?) -> Bool {
        appliedCameraPosition != cameraPosition
    }

    func applyCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition?) {
        guard appliedCameraPosition != cameraPosition else {
            return
        }

        appliedCameraPosition = cameraPosition
        guard let cameraPosition else {
            return
        }

        renderCamera?.setCameraPosition(cameraPosition)
        applyCurrentCameraConstraints()
        syncPitchControlValue(fallbackCameraPosition: cameraPosition)
        notifyCameraPositionChanged()
        renderRuntime.requestFrame()
    }

    func setCameraPosition(_ cameraPosition: ImmersiveMapCameraPosition,
                           requestRenderFrame: Bool = true) {
        appliedCameraPosition = cameraPosition
        renderCamera?.setCameraPosition(cameraPosition)
        applyCurrentCameraConstraints()
        syncPitchControlValue(fallbackCameraPosition: cameraPosition)
        notifyCameraPositionChanged()
        if requestRenderFrame {
            renderRuntime.requestFrame()
        }
    }

    func setCameraState(_ cameraState: ImmersiveMapCameraState) {
        renderCamera?.setCameraState(cameraState)
        applyCurrentCameraConstraints()
        syncPitchControlValue()
        notifyCameraPositionChanged()
        renderRuntime.requestFrame()
    }

    func switchRenderMode() {
        guard let cameraState = renderCamera?.currentCameraState() else {
            return
        }

        presentationStateResolver.switchRenderSurfaceMode(cameraState: cameraState)
        applyCurrentCameraConstraints()
        syncPitchControlValue()
        notifyCameraPositionChanged()
        renderRuntime.requestFrame()
    }

    func rotateCameraYaw(delta: Float) {
        renderCamera?.rotateCameraYaw(delta: delta)
        applyCurrentCameraConstraints()
        notifyCameraPositionChanged()
        renderRuntime.requestFrame()
    }

    func panCamera(deltaX: Double,
                   deltaY: Double) {
        guard let renderCamera else {
            return
        }

        let transition = presentationStateResolver.resolve(cameraState: renderCamera.currentCameraState())
            .presentationState.transition
        renderCamera.panCamera(deltaX: deltaX,
                               deltaY: deltaY,
                               transition: transition)
        notifyCameraPositionChanged()
        renderRuntime.requestFrame()
    }

    func zoomCamera(scale: CGFloat,
                    velocity: CGFloat,
                    anchorPoint: CGPoint? = nil) {
        let stateBefore = renderCamera?.currentCameraState()
        renderCamera?.zoomCamera(scale: scale,
                                 velocity: velocity)
        applyCurrentCameraConstraints()
        applyZoomAnchorCompensation(stateBefore: stateBefore,
                                    anchorPoint: anchorPoint)
        notifyCameraPositionChanged()
        syncPitchControlValue()
        renderRuntime.requestFrame()
    }

    func zoomCamera(delta: Double,
                    anchorPoint: CGPoint? = nil) {
        let stateBefore = renderCamera?.currentCameraState()
        renderCamera?.zoomCamera(delta: delta)
        applyCurrentCameraConstraints()
        applyZoomAnchorCompensation(stateBefore: stateBefore,
                                    anchorPoint: anchorPoint)
        notifyCameraPositionChanged()
        syncPitchControlValue()
        renderRuntime.requestFrame()
    }

    /// Целевая позиция для анимированного anchored-зума (двойной tap/click):
    /// зум меняется на `zoomDelta`, центр смещается так, чтобы точка мира под
    /// `anchorPoint` осталась на месте (с учётом `zoomAnchorFactor`).
    func anchoredZoomTargetPosition(zoomDelta: Double,
                                    anchorPoint: CGPoint) -> ImmersiveMapCameraPosition? {
        guard let stateBefore = renderCamera?.currentCameraState() else {
            return nil
        }

        var stateAfter = stateBefore
        stateAfter.zoom = min(max(0, stateBefore.zoom + zoomDelta), settings.camera.maximumZoom)
        stateAfter.centerWorldMercator = anchorCompensatedCenter(stateBefore: stateBefore,
                                                                 stateAfter: stateAfter,
                                                                 anchorPoint: anchorPoint)
        return stateAfter.cameraPosition()
    }

    /// Сдвигает центр карты после уже применённого зума так, чтобы точка мира под
    /// `anchorPoint` осталась под ним (доля `zoomAnchorFactor`).
    private func applyZoomAnchorCompensation(stateBefore: ImmersiveMapCameraState?,
                                             anchorPoint: CGPoint?) {
        guard let stateBefore,
              let anchorPoint,
              let renderCamera else {
            return
        }

        let stateAfter = renderCamera.currentCameraState()
        let center = anchorCompensatedCenter(stateBefore: stateBefore,
                                             stateAfter: stateAfter,
                                             anchorPoint: anchorPoint)
        guard center != stateAfter.centerWorldMercator else {
            return
        }

        var compensatedState = stateAfter
        compensatedState.centerWorldMercator = center
        renderCamera.setCameraState(compensatedState)
    }

    private func anchorCompensatedCenter(stateBefore: ImmersiveMapCameraState,
                                         stateAfter: ImmersiveMapCameraState,
                                         anchorPoint: CGPoint) -> SIMD2<Double> {
        let input = ZoomAnchorMath.Input(
            anchorPoint: anchorPoint,
            viewportSize: viewportRuntime.bounds.size,
            centerWorldMercator: stateBefore.centerWorldMercator,
            zoomBefore: stateBefore.zoom,
            zoomAfter: stateAfter.zoom,
            bearing: stateBefore.bearing,
            transitionBefore: presentationStateResolver.resolve(cameraState: stateBefore).presentationState.transition,
            transitionAfter: presentationStateResolver.resolve(cameraState: stateAfter).presentationState.transition,
            globeRadiusScale: settings.presentation.globeRadiusScale,
            anchorFactor: settings.camera.zoomAnchorFactor
        )
        return ZoomAnchorMath.compensatedCenterWorldMercator(input)
    }

    func setCameraPitch(_ pitch: Float) {
        renderCamera?.setCameraPitch(pitch)
        applyCurrentCameraConstraints()
        notifyCameraPositionChanged()
        renderRuntime.requestFrame()
    }

    func setCameraBearing(_ bearing: Float) {
        renderCamera?.setCameraBearing(bearing)
        applyCurrentCameraConstraints()
        notifyCameraPositionChanged()
        renderRuntime.requestFrame()
    }

    func notifyCameraPositionChanged(_ position: ImmersiveMapCameraPosition? = nil) {
        guard let position = position ?? currentCameraPosition() else {
            return
        }

        let snapshot = currentCameraSnapshot(position: position)
        cameraNotificationGeneration += 1
        let notificationGeneration = cameraNotificationGeneration

        if let snapshot {
            controller?.updateCurrentCameraSnapshot(snapshot)
        }
        controller?.notifyCameraPositionChanged(position)

        guard notificationGeneration == cameraNotificationGeneration,
              let snapshot else {
            return
        }
        controller?.notifyCameraSnapshotChanged(snapshot)
    }

    func notifyMapBackgroundTap() {
        controller?.notifyMapBackgroundTap()
    }

    func notifyUserInteractionBegan() {
        controller?.notifyUserInteractionBegan()
    }

    func syncPitchControlValue(fallbackCameraPosition: ImmersiveMapCameraPosition? = nil) {
        let currentCameraPosition = renderCamera?.currentCameraPosition()
            ?? fallbackCameraPosition
            ?? appliedCameraPosition
            ?? initialCameraPosition
        controlsRuntime.syncPitch(cameraPosition: currentCameraPosition,
                                  maximumPitch: currentMaximumPitch())
    }

    private func applyCurrentCameraConstraints() {
        guard let renderCamera else {
            return
        }

        renderCamera.applyConstraints(currentCameraConstraints(cameraState: renderCamera.currentCameraState()))
    }

    private func currentCameraConstraints(cameraState: ImmersiveMapCameraState) -> CameraConstraints {
        presentationStateResolver.cameraConstraints(cameraState: cameraState)
    }
}
