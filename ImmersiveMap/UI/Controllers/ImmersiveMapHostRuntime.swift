// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import QuartzCore

/// Logic shared by the UIKit/AppKit host views for owning the runtime graph and `RenderFrameEngine`:
/// applying settings, syncing controllers, creating and recreating the renderer.
/// The platform view is responsible only for layer, layout, input, and lifecycle events.
@MainActor
final class ImmersiveMapHostRuntime {
    let runtimeGraph: ImmersiveMapRuntimeGraph
    private(set) var renderer: RenderFrameEngine?
    private let metalLayer: CAMetalLayer
    private let requestsLayout: () -> Void
    private weak var attachedTourVideoRecorder: ImmersiveMapTourVideoRecorder?
    /// Kept for the tour video recorder: the export rasterizes the current
    /// marker views into the video.
    private var currentMarkerContent: MarkerViewContent?

    init(mapView: ImmersiveMapHostView,
         layer: CAMetalLayer,
         settings: ImmersiveMapSettings,
         initialCameraPosition: ImmersiveMapCameraPosition?,
         requestsLayout: @escaping () -> Void) {
        self.metalLayer = layer
        self.requestsLayout = requestsLayout
        self.runtimeGraph = ImmersiveMapRuntimeGraph(mapView: mapView,
                                                     layer: layer,
                                                     settings: settings,
                                                     initialCameraPosition: initialCameraPosition)
        runtimeGraph.debugOverlayRuntime.apply(settings: settings)

        createRenderer(settings: settings,
                       cameraPosition: initialCameraPosition)
        runtimeGraph.cameraRuntime.syncPitchControlValue()
    }

    func start(displayLinkFactory: DisplayLinkFactory) {
        runtimeGraph.renderRuntime.start(frameDelegate: runtimeGraph.frameRenderDelegate,
                                         displayLinkFactory: displayLinkFactory)
    }

    func requestFrame() {
        runtimeGraph.renderRuntime.requestFrame()
    }

    func handleMemoryPressure() {
        renderer?.handleMemoryWarning()
        // The warning cancels in-flight loads and resets the demand gate;
        // the on-demand loop is asleep at that point, and without an explicit frame
        // the cancelled tiles stay holes until the next gesture - a frame restarts demand.
        requestFrame()
    }

    /// Syncs new parameters from the SwiftUI update hook with the already created host view.
    func update(settings: ImmersiveMapSettings,
                avatarsController: ImmersiveMapAvatarsController?,
                sceneModelsController: ImmersiveMapSceneModelsController? = nil,
                cameraController: ImmersiveMapCameraController?,
                selectionController: ImmersiveMapSelectionController?,
                avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?,
                markerContent: MarkerViewContent?,
                cameraPosition: ImmersiveMapCameraPosition?,
                tourVideoRecorder: ImmersiveMapTourVideoRecorder? = nil) {
        applySettings(settings)
        syncControllers(avatarsController: avatarsController,
                        sceneModelsController: sceneModelsController,
                        cameraController: cameraController,
                        selectionController: selectionController,
                        avatarTapAction: avatarTapAction)
        syncTourVideoRecorder(tourVideoRecorder)
        updateMarkerContent(markerContent)
        runtimeGraph.cameraCommandHandler.applyCameraPosition(cameraPosition)
    }

    func updateMarkerContent(_ markerContent: MarkerViewContent?) {
        currentMarkerContent = markerContent
        runtimeGraph.markerRuntime.update(content: markerContent)
    }

    func dismantle() {
        syncControllers(avatarsController: nil,
                        sceneModelsController: nil,
                        cameraController: nil,
                        selectionController: nil,
                        avatarTapAction: nil)
        syncTourVideoRecorder(nil)
        updateMarkerContent(nil)
    }

    func setEarthSceneEnabled(_ isEnabled: Bool) {
        var settings = runtimeGraph.cameraRuntime.currentSettings
        settings.scene.earth.isEnabled = isEnabled
        applySettings(settings)
    }

    /// Applies new settings to the map runtime and, via the planner, chooses whether
    /// to update the existing renderer in place or recreate it for changes
    /// that affect caches, prepared data, or GPU resources.
    func applySettings(_ settings: ImmersiveMapSettings) {
        let currentSettings = runtimeGraph.cameraRuntime.currentSettings
        guard currentSettings != settings else {
            return
        }

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: currentSettings,
                                                                   to: settings)
        runtimeGraph.cameraRuntime.updateSettings(settings,
                                                  notifiesCameraPositionChanged: plan.requiresRendererRecreation == false)
        runtimeGraph.cameraAnimationRuntime.updateSettings()
        runtimeGraph.controlsRuntime.applyAttribution(settings.resolvedAttribution,
                                                      settings: settings.attribution)
        runtimeGraph.controlsRuntime.applyControlZones(settings.camera.controlZones)
        runtimeGraph.debugOverlayRuntime.apply(settings: settings)
        requestsLayout()
        runtimeGraph.renderRuntime.updateRenderLoopSettings(settings.renderLoop)
        if plan.requiresRendererRecreation {
            recreateRenderer(with: settings)
        } else {
            renderer?.applySettings(settings)
        }

        runtimeGraph.cameraRuntime.syncPitchControlValue()
        requestFrame()
    }

    func syncControllers(avatarsController newAvatarsController: ImmersiveMapAvatarsController?,
                         sceneModelsController newSceneModelsController: ImmersiveMapSceneModelsController? = nil,
                         cameraController newCameraController: ImmersiveMapCameraController?,
                         selectionController newSelectionController: ImmersiveMapSelectionController?,
                         avatarTapAction newAvatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?) {
        runtimeGraph.selectionHandler.setAvatarTapAction(newAvatarTapAction)
        let shouldUpdateAvatarsController = runtimeGraph.avatarRuntime.isAttachedController(newAvatarsController) == false
        let shouldUpdateSceneModelsController = runtimeGraph.sceneModelRuntime.isAttachedController(newSceneModelsController) == false
        let shouldUpdateCameraController = runtimeGraph.cameraRuntime.isAttachedController(newCameraController) == false
        guard shouldUpdateAvatarsController
            || shouldUpdateSceneModelsController
            || shouldUpdateCameraController else {
            runtimeGraph.selectionHandler.syncController(newSelectionController)
            return
        }

        if shouldUpdateAvatarsController {
            runtimeGraph.avatarRuntime.attachController(newAvatarsController,
                                                        selectionHandler: runtimeGraph.selectionHandler,
                                                        renderRuntime: runtimeGraph.renderRuntime)
        }
        if shouldUpdateSceneModelsController {
            runtimeGraph.sceneModelRuntime.attachController(newSceneModelsController,
                                                            renderRuntime: runtimeGraph.renderRuntime)
        }
        if shouldUpdateCameraController {
            runtimeGraph.cameraRuntime.attachController(newCameraController,
                                                        commandHandler: runtimeGraph.cameraCommandHandler)
        }
        runtimeGraph.selectionHandler.syncController(newSelectionController)
    }

    /// Attaches the tour video recorder with owner-scoped semantics matching
    /// the other controllers: a stale host view's detach never clears the
    /// binding a newer host view has installed.
    func syncTourVideoRecorder(_ newRecorder: ImmersiveMapTourVideoRecorder?) {
        guard attachedTourVideoRecorder !== newRecorder else {
            return
        }
        attachedTourVideoRecorder?.detachRuntime(owner: self)
        attachedTourVideoRecorder = newRecorder
        guard let newRecorder else {
            return
        }
        let runtimeGraph = runtimeGraph
        newRecorder.attachRuntime(
            owner: self,
            context: ImmersiveMapVideoExportAttachContext(
                currentSettings: { runtimeGraph.cameraRuntime.currentSettings },
                currentCameraPosition: { runtimeGraph.cameraRuntime.currentCameraPosition() },
                currentAvatarsController: { runtimeGraph.avatarRuntime.currentAvatarController },
                currentMarkerContent: { [weak self] in self?.currentMarkerContent }
            )
        )
    }

    private func createRenderer(settings: ImmersiveMapSettings,
                                cameraPosition: ImmersiveMapCameraPosition?) {
        let renderer = runtimeGraph.rendererBuilder.makeRenderer(layer: metalLayer,
                                                                 settings: settings,
                                                                 cameraPosition: cameraPosition)
        self.renderer = renderer
        runtimeGraph.renderRuntime.attachRenderer(renderer)
        runtimeGraph.avatarRuntime.markSnapshotDirty()
        runtimeGraph.sceneModelRuntime.markSnapshotDirty()
        requestFrame()
    }

    private func recreateRenderer(with settings: ImmersiveMapSettings) {
        // An active fly-to is cancelled WITH completion (success == false): a silently
        // swallowed completion hangs fly chains forever (e.g. a camera tour waits
        // on a continuation that would otherwise never resume).
        runtimeGraph.cameraAnimationRuntime.cancelAnimations()
        let cameraPosition = runtimeGraph.cameraRuntime.cameraPositionForRendererRecreation()
        renderer?.prepareForDiscard()
        runtimeGraph.renderRuntime.detachRenderer()
        renderer = nil
        runtimeGraph.cameraRuntime.clearRenderCamera()
        runtimeGraph.selectionHandler.resetAvatarSelectionSnapshotForRendererRecreation()
        createRenderer(settings: settings,
                       cameraPosition: cameraPosition)
    }

    deinit {
        let detachedGraph = runtimeGraph
        Task { @MainActor in
            detachedGraph.cameraAnimationRuntime.reset()
            detachedGraph.avatarRuntime.detachController()
            detachedGraph.sceneModelRuntime.detachController()
            detachedGraph.cameraRuntime.detachController()
            detachedGraph.selectionHandler.syncController(nil)
            detachedGraph.renderRuntime.stop()
        }
    }
}
