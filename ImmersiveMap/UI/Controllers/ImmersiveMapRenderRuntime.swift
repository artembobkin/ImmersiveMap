// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Owns the render-loop runtime state of a single map view.
/// Wraps `ImmersiveMapRenderDriver`, tracks render activities, frame requests, and renderer attachment.
final class ImmersiveMapRenderRuntime {
    private let driver: ImmersiveMapRenderDriver
    /// The engine the driver renders with, kept here for the frame index the
    /// rendered-frame event reports; the driver owns the attachment.
    private weak var renderer: RenderFrameEngine?
    /// The app's `onFrameRendered` action, if any. Called on the main thread
    /// from the display-link callback, after the frame committed.
    private var frameRenderedAction: ((ImmersiveMapRenderedFrame) -> Void)?

    init(configuration: ImmersiveMapSettings.RenderLoopSettings) {
        self.driver = ImmersiveMapRenderDriver(configuration: configuration)
    }

    var cameraAnimationRenderingActive: Bool {
        driver.cameraAnimationRenderingActive
    }

    @MainActor
    func start(frameDelegate: ImmersiveMapRenderDriverFrameDelegate,
               layer: CAMetalLayer) {
        driver.start(frameDelegate: frameDelegate,
                     layer: layer)
    }

    func stop() {
        driver.stop()
    }

    func setParked(_ parked: Bool) {
        driver.setParked(parked)
    }

    func attachRenderer(_ renderer: RenderFrameEngine) {
        self.renderer = renderer
        driver.attachRenderer(renderer)
    }

    func detachRenderer() {
        renderer = nil
        driver.detachRenderer()
    }

    func setFrameRenderedAction(_ action: ((ImmersiveMapRenderedFrame) -> Void)?) {
        frameRenderedAction = action
    }

    func updateRenderLoopSettings(_ settings: ImmersiveMapSettings.RenderLoopSettings) {
        driver.updateRenderLoopSettings(settings)
    }

    func applyPowerConstraintState(_ constraints: RenderLoopPacing.PowerConstraintState) {
        driver.applyPowerConstraintState(constraints)
    }

    func requestFrame(reason: RenderInvalidationReason = .externalStateChanged) {
        driver.requestFrame(reason: reason)
    }

    func setLabelFadeRenderingActive(_ isActive: Bool) {
        driver.setActivity(.labelFade,
                           active: isActive)
    }

    func setLabelVisibilityCycleRenderingActive(_ isActive: Bool) {
        driver.setActivity(.labelVisibilityCycle,
                           active: isActive)
    }

    func setCameraAnimationRenderingActive(_ isActive: Bool) {
        driver.setActivity(.cameraAnimation,
                           active: isActive)
    }

    func setAvatarAnimationRenderingActive(_ isActive: Bool) {
        driver.setActivity(.avatarAnimation,
                           active: isActive)
    }

    func setSceneModelAnimationRenderingActive(_ isActive: Bool) {
        driver.setActivity(.sceneModelAnimation,
                           active: isActive)
    }

    func setInteractionRenderingActive(_ isActive: Bool) {
        driver.setActivity(.interaction,
                           active: isActive)
    }

    /// See `ImmersiveMapRenderDriver.noteExternalCameraDrive`.
    func noteExternalCameraDrive() {
        driver.noteExternalCameraDrive()
    }

    func applyRenderActivityState(_ state: RenderActivityState) {
        setLabelFadeRenderingActive(state.labelFadeRenderingActive)
        setLabelVisibilityCycleRenderingActive(state.labelVisibilityCycleRenderingActive)
        setAvatarAnimationRenderingActive(state.avatarAnimationRenderingActive)
        setSceneModelAnimationRenderingActive(state.sceneModelAnimationRenderingActive)
    }

    func beginFrame() -> Bool {
        driver.beginFrame()
    }

    func continueFrameAfterPreparation() -> Bool {
        driver.continueFrameAfterPreparation()
    }

    /// Renders one display-link update. `frameStartTime` is when the update
    /// arrived and `targetPresentationTimestamp` when the display is expected
    /// to show it; a frame that schedules is reported to the app's
    /// `onFrameRendered` action with both, a skipped update reports nothing.
    @discardableResult
    func renderFrame(layer: CAMetalLayer,
                     drawable: any CAMetalDrawable,
                     frameStartTime: CFTimeInterval,
                     targetPresentationTimestamp: CFTimeInterval,
                     viewportRuntime: ImmersiveMapViewportRuntime) -> Bool {
        let didSchedule = driver.renderFrame(layer: layer,
                                             drawable: drawable,
                                             isRenderable: viewportRuntime.isRenderable)
        guard didSchedule, let frameRenderedAction else {
            return didSchedule
        }
        let frame = ImmersiveMapRenderedFrame(frameIndex: renderer?.currentDiagnostics?.frameIndex ?? 0,
                                              cpuDuration: max(0, CACurrentMediaTime() - frameStartTime),
                                              targetPresentationTimestamp: targetPresentationTimestamp)
        frameRenderedAction(frame)
        return didSchedule
    }
}
