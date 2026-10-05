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
    private lazy var pathFollowController = ImmersiveMapCameraPathFollowController(
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
    private var boundsPullIsActive = false
    private var boundsPullLastTickTime: CFTimeInterval?
    private var globeUprightPullIsActive = false
    private var globeUprightPullLastTickTime: CFTimeInterval?

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

    var isCameraPathFollowActive: Bool {
        pathFollowController.isActive
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
        // Manual angle control wins over a traversal, same as over a flight.
        pathFollowController.cancel(notifyCompletion: true)

        setBearingTarget(bearing, currentTime: currentTime)
        setPitchTarget(pitch, currentTime: currentTime)
    }

    /// Accepts a target pitch. Instead of applying instantly, it sets a goal toward which the actual
    /// pitch is eased per frame (smoothing). If follow is disabled, applies instantly.
    func setPitchTarget(_ pitch: Float, currentTime: CFTimeInterval = CACurrentMediaTime()) {
        // A target above what the globe's upright pull allows would only be
        // pulled back, so the tilt stops there.
        let maximumPitch = min(cameraRuntime.currentMaximumPitch(),
                               cameraRuntime.currentGlobeUprightWindow()?.maximumPitch ?? .infinity)
        let clampedTarget = min(max(cameraRuntime.currentMinimumPitch(), pitch), maximumPitch)
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
        let maximumAbsoluteBearing = min(cameraRuntime.currentMaximumAbsoluteBearing(),
                                         cameraRuntime.currentGlobeUprightWindow()?.maximumAbsoluteBearing ?? .pi)
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

    func startCameraPathFollow(path: ImmersiveMapGeoPath,
                               duration: TimeInterval,
                               curve: ImmersiveMapPathAnimationCurve,
                               options: ImmersiveMapCameraFollowOptions,
                               completion: ((Bool) -> Void)?,
                               currentTime: CFTimeInterval) {
        pathFollowController.start(path: path,
                                   duration: duration,
                                   curve: curve,
                                   options: options,
                                   completion: completion,
                                   currentTime: currentTime)
    }

    func cancelCameraPathFollow(notifyCompletion: Bool = true) {
        pathFollowController.cancel(notifyCompletion: notifyCompletion)
    }

    func advanceCameraPathFollowIfNeeded(currentTime: CFTimeInterval) {
        pathFollowController.advanceIfNeeded(currentTime: currentTime)
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
        // The follow goes last: its completion runs synchronously, and a camera
        // command the app issues from there must not be undone by the rest of
        // this sequence.
        flightController.cancel(notifyCompletion: true)
        pathFollowController.cancel(notifyCompletion: true)
    }

    func advanceAnimationsIfNeeded(currentTime: CFTimeInterval) {
        advanceCameraPitchFollowIfNeeded(currentTime: currentTime)
        advanceCameraBearingFollowIfNeeded(currentTime: currentTime)
        advanceGlobeCameraPanInertiaIfNeeded(currentTime: currentTime)
        pathFollowController.advanceIfNeeded(currentTime: currentTime)
        flightController.advanceIfNeeded(currentTime: currentTime)
        // Last, so the pulls act on the camera every other animation left
        // this frame, and a flight that ended hands over in the same frame.
        advanceBoundsPullIfNeeded(currentTime: currentTime)
        advanceGlobeUprightPullIfNeeded(currentTime: currentTime)
    }

    func reset() {
        globeCameraPanInertia.cancel()
        globeCameraPanInertiaIsActive = false
        cameraPitchFollow.cancel()
        cameraPitchFollowIsActive = false
        cameraBearingFollow.cancel()
        cameraBearingFollowIsActive = false
        pathFollowController.reset()
        flightController.reset()
        boundsPullIsActive = false
        boundsPullLastTickTime = nil
        globeUprightPullIsActive = false
        globeUprightPullLastTickTime = nil
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

        let step = cameraBearingFollow.advance(currentBearing: currentBearing,
                                               currentTime: currentTime,
                                               maximumAbsoluteBearing: cameraRuntime.currentMaximumAbsoluteBearing())
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

    /// The elastic bounds pull on every frame, gestures and the pan inertia
    /// included, so the pull reads as a constant force a drag works against.
    /// Only a flight or a path follow owns the center outright, and the
    /// pull waits for it to finish. A center inside the area costs one clamp
    /// and starts nothing.
    private func advanceBoundsPullIfNeeded(currentTime: CFTimeInterval) {
        guard flightController.isActive == false,
              pathFollowController.isActive == false else {
            boundsPullLastTickTime = nil
            setBoundsPullActive(false)
            return
        }

        // The same frame-gap cap as the pan inertia, so a hitch does not
        // snap the camera back in one step.
        let deltaTime = boundsPullLastTickTime.map {
            GlobeCameraPanInertiaMath.clampedDeltaTime(currentTime - $0)
        } ?? 0
        let isPulling = cameraRuntime.advanceBoundsPull(deltaTime: deltaTime)
        boundsPullLastTickTime = isPulling ? currentTime : nil
        setBoundsPullActive(isPulling)
    }

    private func setBoundsPullActive(_ isActive: Bool) {
        guard boundsPullIsActive != isActive else {
            return
        }
        boundsPullIsActive = isActive
        refreshRenderingState()
    }

    /// The globe's upright pull on every frame, gestures included, the way
    /// the bounds pull runs: zooming out straightens the globe while the
    /// pinch is still under way, and a rotation works against the pull and
    /// springs back when it ends. A flight or a path follow owns the angles
    /// outright, and the pull waits for it to finish.
    private func advanceGlobeUprightPullIfNeeded(currentTime: CFTimeInterval) {
        guard flightController.isActive == false,
              pathFollowController.isActive == false,
              let window = cameraRuntime.currentGlobeUprightWindow(),
              let bearing = cameraRuntime.currentBearing,
              let pitch = cameraRuntime.currentPitch else {
            globeUprightPullLastTickTime = nil
            setGlobeUprightPullActive(false)
            return
        }

        let deltaTime = globeUprightPullLastTickTime.map {
            GlobeCameraPanInertiaMath.clampedDeltaTime(currentTime - $0)
        } ?? 0
        let halfLife = cameraRuntime.currentSettings.camera.globeUprightPull?.halfLife ?? 0
        let step = GlobeUprightPull.step(bearing: bearing,
                                         pitch: pitch,
                                         window: window,
                                         deltaTime: deltaTime,
                                         halfLife: halfLife)
        // A follow whose target was set under a wider window would hold the
        // angle against the pull for good, so the pull takes the angle over.
        if step.bearing != bearing {
            cancelCameraBearingFollow()
            cameraRuntime.setCameraBearing(step.bearing)
        }
        if step.pitch != pitch {
            cancelCameraPitchFollow()
            cameraRuntime.setCameraPitch(step.pitch)
        }
        globeUprightPullLastTickTime = step.isPulling ? currentTime : nil
        setGlobeUprightPullActive(step.isPulling)
    }

    private func setGlobeUprightPullActive(_ isActive: Bool) {
        guard globeUprightPullIsActive != isActive else {
            return
        }
        globeUprightPullIsActive = isActive
        refreshRenderingState()
    }

    func refreshRenderingState() {
        renderRuntime.setCameraAnimationRenderingActive(globeCameraPanInertiaIsActive
                                                        || flightController.isActive
                                                        || pathFollowController.isActive
                                                        || cameraPitchFollowIsActive
                                                        || cameraBearingFollowIsActive
                                                        || boundsPullIsActive
                                                        || globeUprightPullIsActive)
    }
}
