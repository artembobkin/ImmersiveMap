// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import QuartzCore

/// Logic shared by the UIKit/AppKit host views for owning the runtime graph and `RenderFrameEngine`:
/// applying settings, syncing controllers, creating and recreating the renderer.
/// The platform view is responsible only for layer, layout, input, and lifecycle events.
@MainActor
final class ImmersiveMapHostRuntime {
    let runtimeGraph: ImmersiveMapRuntimeGraph
    private(set) var renderer: RenderFrameEngine?
    private let metalLayer: CAMetalLayer
    private weak var mapView: ImmersiveMapHostView?
    private let requestsLayout: () -> Void
    private weak var attachedTourVideoRecorder: ImmersiveMapTourVideoRecorder?
    /// Kept for the tour video recorder: the export rasterizes the current
    /// marker views into the video.
    private var currentMarkerContent: MarkerViewContent?
    private var powerStateObservers: NotificationObserverBag?

    init(mapView: ImmersiveMapHostView,
         layer: CAMetalLayer,
         settings: ImmersiveMapSettings,
         initialCameraPosition: ImmersiveMapCameraPosition?,
         requestsLayout: @escaping () -> Void) {
        self.metalLayer = layer
        self.mapView = mapView
        self.requestsLayout = requestsLayout
        self.runtimeGraph = ImmersiveMapRuntimeGraph(mapView: mapView,
                                                     layer: layer,
                                                     settings: settings,
                                                     initialCameraPosition: initialCameraPosition)
        runtimeGraph.debugOverlayRuntime.apply(settings: settings)
        // The debug panel edits live settings (the shadow group), and they
        // take the same road as any other change.
        runtimeGraph.debugOverlayRuntime.onSettingsChangeRequested = { [weak self] requested in
            self?.applySettings(requested)
        }
        mapView.applyBackgroundTransparency(settings.scene.space.isTransparent)

        createRenderer(settings: settings,
                       cameraPosition: initialCameraPosition)
        runtimeGraph.cameraRuntime.syncPitchControlValue()
        subscribeToPowerStateNotifications()
    }

    /// Thermal pressure and Low Power Mode cap the display-link rates for the
    /// whole lifetime of the host: serious heat drops rendering to 60, critical
    /// to 30, and both (as well as Low Power Mode) revoke ProMotion headroom.
    /// The on-demand pacing contract is untouched: an idle map still renders
    /// nothing at all.
    private func subscribeToPowerStateNotifications() {
        let center = NotificationCenter.default
        powerStateObservers = NotificationObserverBag(observers: [
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyCurrentPowerConstraintState()
                }
            },
            center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                               object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyCurrentPowerConstraintState()
                }
            }
        ])
        applyCurrentPowerConstraintState()
    }

    private func applyCurrentPowerConstraintState() {
        let processInfo = ProcessInfo.processInfo
        let constraints = RenderLoopPacing.PowerConstraintState.resolve(thermalState: processInfo.thermalState,
                                                                    isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled)
        runtimeGraph.renderRuntime.applyPowerConstraintState(constraints)
    }

    /// Starts the render loop. The `CAMetalDisplayLink` is created from the
    /// host layer here, after `init` has already built the renderer and
    /// stamped the layer's Metal device.
    func start() {
        runtimeGraph.renderRuntime.start(frameDelegate: runtimeGraph.frameRenderDelegate,
                                         layer: metalLayer)
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
                routesController: ImmersiveMapRoutesController? = nil,
                cameraController: ImmersiveMapCameraController?,
                selectionController: ImmersiveMapSelectionController?,
                avatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?,
                sceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)? = nil,
                markerContent: MarkerViewContent?,
                cameraPosition: ImmersiveMapCameraPosition?,
                tourVideoRecorder: ImmersiveMapTourVideoRecorder? = nil) {
        applySettings(settings)
        syncControllers(avatarsController: avatarsController,
                        sceneModelsController: sceneModelsController,
                        routesController: routesController,
                        cameraController: cameraController,
                        selectionController: selectionController,
                        avatarTapAction: avatarTapAction,
                        sceneModelTapAction: sceneModelTapAction)
        syncTourVideoRecorder(tourVideoRecorder)
        updateMarkerContent(markerContent)
        runtimeGraph.cameraCommandHandler.applyCameraPosition(cameraPosition)
    }

    func updateMarkerContent(_ markerContent: MarkerViewContent?) {
        currentMarkerContent = markerContent
        runtimeGraph.markerRuntime.update(content: markerContent)
    }

    func dismantle() {
        // Parking cancels camera flights, so a path animation cannot outlive the
        // view either: its completion resolves here instead of hanging until the
        // parked view is finally dropped.
        runtimeGraph.sceneModelRuntime.cancelAllPathAnimations()
        syncControllers(avatarsController: nil,
                        sceneModelsController: nil,
                        routesController: nil,
                        cameraController: nil,
                        selectionController: nil,
                        avatarTapAction: nil,
                        sceneModelTapAction: nil)
        syncTourVideoRecorder(nil)
        updateMarkerContent(nil)
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
        if currentSettings.scene.space.isTransparent != settings.scene.space.isTransparent {
            mapView?.applyBackgroundTransparency(settings.scene.space.isTransparent)
        }
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
                         routesController newRoutesController: ImmersiveMapRoutesController? = nil,
                         cameraController newCameraController: ImmersiveMapCameraController?,
                         selectionController newSelectionController: ImmersiveMapSelectionController?,
                         avatarTapAction newAvatarTapAction: ((ImmersiveMapAvatarTapEvent) -> Void)?,
                         sceneModelTapAction newSceneModelTapAction: ((ImmersiveMapSceneModelTapEvent) -> Void)? = nil) {
        runtimeGraph.selectionHandler.setAvatarTapAction(newAvatarTapAction)
        runtimeGraph.selectionHandler.setSceneModelTapAction(newSceneModelTapAction)
        let shouldUpdateAvatarsController = runtimeGraph.avatarRuntime.isAttachedController(newAvatarsController) == false
        let shouldUpdateSceneModelsController = runtimeGraph.sceneModelRuntime.isAttachedController(newSceneModelsController) == false
        let shouldUpdateRoutesController = runtimeGraph.routeRuntime.isAttachedController(newRoutesController) == false
        let shouldUpdateCameraController = runtimeGraph.cameraRuntime.isAttachedController(newCameraController) == false
        guard shouldUpdateAvatarsController
            || shouldUpdateSceneModelsController
            || shouldUpdateRoutesController
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
                                                            selectionHandler: runtimeGraph.selectionHandler,
                                                            renderRuntime: runtimeGraph.renderRuntime)
        }
        if shouldUpdateRoutesController {
            runtimeGraph.routeRuntime.attachController(newRoutesController,
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
        // A fresh renderer starts with an empty presentation store, so any
        // path animation it would have finished is gone: resolve the app's
        // completions now instead of leaving chains waiting forever.
        runtimeGraph.sceneModelRuntime.cancelAllPathAnimations()
        let renderer = runtimeGraph.rendererBuilder.makeRenderer(layer: metalLayer,
                                                                 settings: settings,
                                                                 cameraPosition: cameraPosition)
        self.renderer = renderer
        runtimeGraph.renderRuntime.attachRenderer(renderer)
        runtimeGraph.avatarRuntime.markSnapshotDirty()
        runtimeGraph.sceneModelRuntime.markSnapshotDirty()
        runtimeGraph.routeRuntime.markSnapshotDirty()
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
        runtimeGraph.selectionHandler.resetSelectionSnapshotsForRendererRecreation()
        createRenderer(settings: settings,
                       cameraPosition: cameraPosition)
    }

    deinit {
        let detachedGraph = runtimeGraph
        Task { @MainActor in
            detachedGraph.cameraAnimationRuntime.reset()
            detachedGraph.avatarRuntime.detachController()
            detachedGraph.sceneModelRuntime.cancelAllPathAnimations()
            detachedGraph.sceneModelRuntime.detachController()
            detachedGraph.routeRuntime.detachController()
            detachedGraph.cameraRuntime.detachController()
            detachedGraph.selectionHandler.syncController(nil)
            detachedGraph.renderRuntime.stop()
        }
    }
}

/// Removes its notification observers when deallocated, so a `@MainActor`
/// owner does not have to touch the non-Sendable tokens from its nonisolated
/// deinit.
private final class NotificationObserverBag {
    private let observers: [NSObjectProtocol]

    init(observers: [NSObjectProtocol]) {
        self.observers = observers
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
