// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Owns the render-loop runtime state of a single map view.
/// Wraps `ImmersiveMapRenderDriver`, tracks render activities, frame requests, and renderer attachment.
final class ImmersiveMapRenderRuntime {
    private let driver: ImmersiveMapRenderDriver

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
        driver.attachRenderer(renderer)
    }

    func detachRenderer() {
        driver.detachRenderer()
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

    func setRouteAnimationRenderingActive(_ isActive: Bool) {
        driver.setActivity(.routeAnimation,
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
        setRouteAnimationRenderingActive(state.routeAnimationRenderingActive)
    }

    func beginFrame() -> Bool {
        driver.beginFrame()
    }

    func continueFrameAfterPreparation() -> Bool {
        driver.continueFrameAfterPreparation()
    }

    @discardableResult
    func renderFrame(layer: CAMetalLayer,
                     drawable: any CAMetalDrawable,
                     viewportRuntime: ImmersiveMapViewportRuntime) -> Bool {
        driver.renderFrame(layer: layer,
                           drawable: drawable,
                           isRenderable: viewportRuntime.isRenderable)
    }
}
