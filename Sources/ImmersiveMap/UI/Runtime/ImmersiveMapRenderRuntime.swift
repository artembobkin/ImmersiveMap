// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Owns the render-loop runtime state of a single map view.
/// Wraps `ImmersiveMapRenderDriver`, tracks render activities, frame requests, and renderer attachment.
package final class ImmersiveMapRenderRuntime {
    private let driver: ImmersiveMapRenderDriver
    /// The engine the driver renders with, kept here for the frame index the
    /// rendered-frame event reports; the driver owns the attachment.
    private weak var renderer: RenderFrameEngine?
    /// The app's `onFrameRendered` action, if any. Called on the main thread
    /// from the display-link callback, after the frame committed.
    private var frameRenderedAction: ((ImmersiveMapRenderedFrame) -> Void)?
    /// The app's `onTerrainSurroundingsChange` action, if any, called on the
    /// main thread after a frame whose reading differs from the last one
    /// delivered, and after the first frame.
    private var terrainSurroundingsAction: ((ImmersiveMapTerrainSurroundings?) -> Void)?
    private var deliveredTerrainSurroundings: ImmersiveMapTerrainSurroundings?
    private var hasDeliveredTerrainSurroundings = false

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

    /// An action set where there was none hears the current reading with
    /// the next frame. SwiftUI hands the same action again on every update
    /// of the hierarchy, which changes nothing here.
    func setTerrainSurroundingsAction(_ action: ((ImmersiveMapTerrainSurroundings?) -> Void)?) {
        if terrainSurroundingsAction == nil, action != nil {
            hasDeliveredTerrainSurroundings = false
        }
        terrainSurroundingsAction = action
    }

    func updateRenderLoopSettings(_ settings: ImmersiveMapSettings.RenderLoopSettings) {
        driver.updateRenderLoopSettings(settings)
    }

    func applyPowerConstraintState(_ constraints: RenderLoopPacing.PowerConstraintState) {
        driver.applyPowerConstraintState(constraints)
    }

    package func requestFrame(reason: RenderInvalidationReason = .externalStateChanged) {
        driver.requestFrame(reason: reason)
    }

    func setLabelFadeRenderingActive(_ isActive: Bool) {
        driver.setActivity(.labelFade,
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

    func setExtrusionRiseRenderingActive(_ isActive: Bool) {
        driver.setActivity(.extrusionRise,
                           active: isActive)
    }

    func setAnimatedZoomRenderingActive(_ isActive: Bool) {
        driver.setActivity(.animatedZoom,
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
        setAvatarAnimationRenderingActive(state.avatarAnimationRenderingActive)
        setSceneModelAnimationRenderingActive(state.sceneModelAnimationRenderingActive)
        setExtrusionRiseRenderingActive(state.extrusionRiseRenderingActive)
        setAnimatedZoomRenderingActive(state.animatedZoomRenderingActive)
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
        reportTerrainSurroundings()
        guard didSchedule, let frameRenderedAction else {
            return didSchedule
        }
        let frame = ImmersiveMapRenderedFrame(frameIndex: renderer?.currentDiagnostics?.frameIndex ?? 0,
                                              cpuDuration: max(0, CACurrentMediaTime() - frameStartTime),
                                              targetPresentationTimestamp: targetPresentationTimestamp)
        frameRenderedAction(frame)
        return didSchedule
    }

    /// The engine's reading of the country around the camera
    /// (`RenderFrameEngine.currentTerrainSurroundings`), handed to the app
    /// when it differs from the last one it heard. Whether or not the frame
    /// reached a drawable: the reading is the frame's input, not its output.
    private func reportTerrainSurroundings() {
        guard let terrainSurroundingsAction, let renderer else {
            return
        }
        let surroundings = renderer.currentTerrainSurroundings
        guard hasDeliveredTerrainSurroundings == false || surroundings != deliveredTerrainSurroundings else {
            return
        }
        deliveredTerrainSurroundings = surroundings
        hasDeliveredTerrainSurroundings = true
        terrainSurroundingsAction(surroundings)
    }
}
