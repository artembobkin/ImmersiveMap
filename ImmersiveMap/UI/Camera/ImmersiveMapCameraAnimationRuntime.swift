// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import QuartzCore

/// Owns time-based camera animations for a single map view.
/// Coordinates camera flights and globe pan inertia, then synchronizes render-loop activity.
@MainActor
final class ImmersiveMapCameraAnimationRuntime {
    private let cameraRuntime: ImmersiveMapCameraRuntime
    private let interactionRuntime: ImmersiveMapInteractionRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime
    private lazy var flightController = ImmersiveMapCameraFlightController(
        cameraRuntime: cameraRuntime,
        interactionRuntime: interactionRuntime,
        cameraAnimationRuntime: self,
        renderRuntime: renderRuntime
    )
    private lazy var globeCameraPanInertia = GlobeCameraPanInertia(configuration: makeGlobeCameraPanInertiaConfiguration())
    private var globeCameraPanInertiaIsActive = false
    private lazy var cameraPitchFollow = CameraPitchFollow(configuration: makeCameraPitchFollowConfiguration())
    private var cameraPitchFollowIsActive = false
    private lazy var cameraBearingFollow = CameraBearingFollow(configuration: makeCameraBearingFollowConfiguration())
    private var cameraBearingFollowIsActive = false

    init(cameraRuntime: ImmersiveMapCameraRuntime,
         interactionRuntime: ImmersiveMapInteractionRuntime,
         renderRuntime: ImmersiveMapRenderRuntime) {
        self.cameraRuntime = cameraRuntime
        self.interactionRuntime = interactionRuntime
        self.renderRuntime = renderRuntime
    }

    var isCameraFlightActive: Bool {
        flightController.isActive
    }

    func updateSettings() {
        globeCameraPanInertiaIsActive = globeCameraPanInertia.updateConfiguration(makeGlobeCameraPanInertiaConfiguration())
        cameraPitchFollowIsActive = cameraPitchFollow.updateConfiguration(makeCameraPitchFollowConfiguration())
        cameraBearingFollowIsActive = cameraBearingFollow.updateConfiguration(makeCameraBearingFollowConfiguration())
        refreshRenderingState()
    }

    /// Sets target angles (bearing + pitch) from the camera control, toward which the actual
    /// angles are eased per frame (smoothing). Interrupts an active camera flight, since manual control wins.
    func setCameraAngleTarget(bearing: Float,
                              pitch: Float,
                              currentTime: CFTimeInterval = CACurrentMediaTime()) {
        if flightController.isActive {
            flightController.cancel(notifyCompletion: true)
        }

        setBearingTarget(bearing, currentTime: currentTime)
        setPitchTarget(pitch, currentTime: currentTime)
    }

    /// Accepts a target pitch. Instead of applying instantly, it sets a goal toward which the actual
    /// pitch is eased per frame (smoothing). If follow is disabled, applies instantly.
    func setPitchTarget(_ pitch: Float, currentTime: CFTimeInterval = CACurrentMediaTime()) {
        let clampedTarget = min(max(0, pitch), cameraRuntime.currentMaximumPitch())
        guard cameraPitchFollow.retarget(clampedTarget, currentTime: currentTime) else {
            cameraPitchFollowIsActive = false
            cameraRuntime.setCameraPitch(clampedTarget)
            refreshRenderingState()
            return
        }

        cameraPitchFollowIsActive = true
        refreshRenderingState()
        renderRuntime.requestFrame()
    }

    /// Accepts a target bearing. The actual bearing is eased toward the goal per frame along the
    /// shortest angular path. If follow is disabled, applies instantly.
    func setBearingTarget(_ bearing: Float, currentTime: CFTimeInterval = CACurrentMediaTime()) {
        let maximumAbsoluteBearing = cameraRuntime.currentMaximumAbsoluteBearing()
        let clampedTarget = min(max(bearing, -maximumAbsoluteBearing), maximumAbsoluteBearing)
        guard cameraBearingFollow.retarget(clampedTarget, currentTime: currentTime) else {
            cameraBearingFollowIsActive = false
            cameraRuntime.setCameraBearing(clampedTarget)
            refreshRenderingState()
            return
        }

        cameraBearingFollowIsActive = true
        refreshRenderingState()
        renderRuntime.requestFrame()
    }

    func cancelCameraPitchFollow() {
        cameraPitchFollow.cancel()
        cameraPitchFollowIsActive = false
        refreshRenderingState()
    }

    func cancelCameraBearingFollow() {
        cameraBearingFollow.cancel()
        cameraBearingFollowIsActive = false
        refreshRenderingState()
    }

    func startCameraFlight(to cameraPosition: ImmersiveMapCameraPosition,
                           options: CameraFlightOptions,
                           completion: ((Bool) -> Void)?,
                           currentTime: CFTimeInterval) {
        flightController.start(to: cameraPosition,
                               options: options,
                               completion: completion,
                               currentTime: currentTime)
    }

    func cancelCameraFlight(notifyCompletion: Bool = true) {
        flightController.cancel(notifyCompletion: notifyCompletion)
    }

    func advanceCameraFlightIfNeeded(currentTime: CFTimeInterval) {
        flightController.advanceIfNeeded(currentTime: currentTime)
    }

    func startGlobeCameraPanInertiaIfNeeded(initialVelocity: CGPoint,
                                            currentTime: CFTimeInterval = CACurrentMediaTime()) {
        guard cameraRuntime.isSphericalRenderSurfaceActive() else {
            cancelGlobeCameraPanInertia()
            return
        }

        let didStart = globeCameraPanInertia.start(initialVelocity: initialVelocity,
                                                   currentTime: currentTime)
        globeCameraPanInertiaIsActive = didStart
        refreshRenderingState()
        if didStart {
            renderRuntime.requestFrame()
        }
    }

    func cancelGlobeCameraPanInertia() {
        globeCameraPanInertia.cancel()
        globeCameraPanInertiaIsActive = false
        refreshRenderingState()
    }

    func cancelAnimations() {
        cancelGlobeCameraPanInertia()
        cancelCameraPitchFollow()
        cancelCameraBearingFollow()
        flightController.cancel(notifyCompletion: true)
    }

    func advanceAnimationsIfNeeded(currentTime: CFTimeInterval) {
        advanceCameraPitchFollowIfNeeded(currentTime: currentTime)
        advanceCameraBearingFollowIfNeeded(currentTime: currentTime)
        advanceGlobeCameraPanInertiaIfNeeded(currentTime: currentTime)
        flightController.advanceIfNeeded(currentTime: currentTime)
    }

    func reset() {
        globeCameraPanInertia.cancel()
        globeCameraPanInertiaIsActive = false
        cameraPitchFollow.cancel()
        cameraPitchFollowIsActive = false
        cameraBearingFollow.cancel()
        cameraBearingFollowIsActive = false
        flightController.reset()
        refreshRenderingState()
    }

    private func makeGlobeCameraPanInertiaConfiguration() -> GlobeCameraPanInertia.Configuration {
        let settings = cameraRuntime.currentSettings.camera
        return GlobeCameraPanInertia.Configuration(isEnabled: settings.globePanInertiaEnabled,
                                                   halfLife: settings.globePanInertiaHalfLife,
                                                   activationVelocity: settings.globePanInertiaActivationVelocity,
                                                   stopVelocity: settings.globePanInertiaStopVelocity,
                                                   maximumInitialVelocity: settings.globePanInertiaMaxInitialVelocity)
    }

    private func makeCameraPitchFollowConfiguration() -> CameraPitchFollow.Configuration {
        let settings = cameraRuntime.currentSettings.camera
        return CameraPitchFollow.Configuration(isEnabled: settings.pitchFollowEnabled,
                                               halfLife: settings.pitchFollowHalfLife)
    }

    private func advanceCameraPitchFollowIfNeeded(currentTime: CFTimeInterval) {
        guard cameraPitchFollowIsActive else {
            return
        }

        // A camera flight owns the entire camera pose (including pitch), so we yield to it.
        guard flightController.isActive == false,
              let currentPitch = cameraRuntime.currentPitch else {
            cancelCameraPitchFollow()
            return
        }

        let step = cameraPitchFollow.advance(currentPitch: currentPitch, currentTime: currentTime)
        if step.pitch != currentPitch {
            cameraRuntime.setCameraPitch(step.pitch)
        }
        cameraPitchFollowIsActive = step.isActive
        if step.isActive == false {
            refreshRenderingState()
        }
    }

    private func makeCameraBearingFollowConfiguration() -> CameraBearingFollow.Configuration {
        let settings = cameraRuntime.currentSettings.camera
        return CameraBearingFollow.Configuration(isEnabled: settings.bearingFollowEnabled,
                                                 halfLife: settings.bearingFollowHalfLife)
    }

    private func advanceCameraBearingFollowIfNeeded(currentTime: CFTimeInterval) {
        guard cameraBearingFollowIsActive else {
            return
        }

        // A camera flight owns the entire camera pose (including bearing), so we yield to it.
        guard flightController.isActive == false,
              let currentBearing = cameraRuntime.currentBearing else {
            cancelCameraBearingFollow()
            return
        }

        let step = cameraBearingFollow.advance(currentBearing: currentBearing, currentTime: currentTime)
        if step.bearing != currentBearing {
            cameraRuntime.setCameraBearing(step.bearing)
        }
        cameraBearingFollowIsActive = step.isActive
        if step.isActive == false {
            refreshRenderingState()
        }
    }

    private func advanceGlobeCameraPanInertiaIfNeeded(currentTime: CFTimeInterval) {
        guard globeCameraPanInertiaIsActive else {
            refreshRenderingState()
            return
        }

        guard interactionRuntime.hasActiveUserInteraction == false,
              cameraRuntime.isSphericalRenderSurfaceActive() else {
            cancelGlobeCameraPanInertia()
            return
        }

        let step = globeCameraPanInertia.advance(currentTime: currentTime)
        globeCameraPanInertiaIsActive = step.isActive
        if step.translation != .zero {
            let scale = cameraRuntime.currentSettings.camera.gesturePanTranslationScale
            cameraRuntime.panCamera(deltaX: Double(step.translation.x) * scale,
                                    deltaY: Double(step.translation.y) * scale)
        }

        if step.isActive == false {
            refreshRenderingState()
        }
    }

    func refreshRenderingState() {
        renderRuntime.setCameraAnimationRenderingActive(globeCameraPanInertiaIsActive
                                                        || flightController.isActive
                                                        || cameraPitchFollowIsActive
                                                        || cameraBearingFollowIsActive)
    }
}
