// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Composition root for the platform host view's runtime collaborators.
/// Creates and owns feature runtimes/controllers, then hands the view its direct dependencies.
@MainActor
final class ImmersiveMapRuntimeGraph {
    let gestureController: MapGestureController
    let renderRuntime: ImmersiveMapRenderRuntime
    let viewportRuntime: ImmersiveMapViewportRuntime
    let avatarRuntime: ImmersiveMapAvatarRuntime
    let markerRuntime: ImmersiveMapMarkerRuntime
    let sceneModelRuntime: ImmersiveMapSceneModelRuntime
    let controlsRuntime: ImmersiveMapControlsRuntime
    let cameraRuntime: ImmersiveMapCameraRuntime
    let interactionRuntime: ImmersiveMapInteractionRuntime
    let cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime
    let cameraCommandHandler: ImmersiveMapCameraCommandHandler
    let selectionHandler: ImmersiveMapSelectionHandler
    /// The debug panel over the map, once one is installed
    /// (`installDebugPanel`): nil in an app that links no panel.
    private(set) var debugPanelRuntime: (any ImmersiveMapDebugPanelRuntime)?
    /// What a panel reads and drags, kept for the frames whether or not
    /// a panel is ever installed, and the view a panel lays itself into.
    /// The view is held weakly: it owns this graph through the host
    /// runtime, and a strong reference here kept every dismantled map
    /// view alive with its renderer.
    private let debugOverlayControls: DebugOverlayControlState
    private let debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore
    private let tileTraceRecorder: TileTraceRecorder
    private let baseLabelTraceRecorder: BaseLabelTraceRecorder
    private weak var mapView: ImmersiveMapHostView?
    let tapHandler: ImmersiveMapTapHandler
    let rendererBuilder: ImmersiveMapRendererBuilder
    let frameRenderDelegate: ImmersiveMapFrameRenderDelegate

    init(mapView: ImmersiveMapHostView,
         layer: CAMetalLayer,
         settings: ImmersiveMapSettings,
         initialCameraPosition: ImmersiveMapCameraPosition?) {
        let gestureController = MapGestureController(mapView: mapView)
        let renderRuntime = ImmersiveMapRenderRuntime(configuration: settings.renderLoop)
        let viewportRuntime = ImmersiveMapViewportRuntime()
        let avatarRuntime = ImmersiveMapAvatarRuntime()
        let sceneModelRuntime = ImmersiveMapSceneModelRuntime()
        let markerRuntime = ImmersiveMapMarkerRuntime(viewportRuntime: viewportRuntime,
                                                      renderRuntime: renderRuntime)
        markerRuntime.attach(hostView: mapView)
        #if canImport(UIKit)
        let controlsRuntime = ImmersiveMapControlsRuntime(mapView: mapView,
                                                          mapPanGesture: gestureController.panGesture,
                                                          settings: settings)
        #else
        let controlsRuntime = ImmersiveMapControlsRuntime(mapView: mapView,
                                                          settings: settings)
        #endif
        let cameraRuntime = ImmersiveMapCameraRuntime(settings: settings,
                                                      initialCameraPosition: initialCameraPosition,
                                                      renderRuntime: renderRuntime,
                                                      controlsRuntime: controlsRuntime,
                                                      viewportRuntime: viewportRuntime)
        let interactionRuntime = ImmersiveMapInteractionRuntime(cameraRuntime: cameraRuntime,
                                                                renderRuntime: renderRuntime)
        let cameraAnimationRuntime = ImmersiveMapCameraAnimationRuntime(cameraRuntime: cameraRuntime,
                                                                        interactionRuntime: interactionRuntime,
                                                                        renderRuntime: renderRuntime)
        let cameraCommandHandler = ImmersiveMapCameraCommandHandler(cameraRuntime: cameraRuntime,
                                                                    cameraAnimationRuntime: cameraAnimationRuntime)
        let selectionHandler = ImmersiveMapSelectionHandler(avatarRuntime: avatarRuntime,
                                                            sceneModelRuntime: sceneModelRuntime,
                                                            viewportRuntime: viewportRuntime,
                                                            renderRuntime: renderRuntime)
        let debugOverlayControls = DebugOverlayControlState()
        let debugOverlayHUDSnapshotStore = DebugOverlayHUDSnapshotStore()
        let tileTraceRecorder = TileTraceRecorder()
        let baseLabelTraceRecorder = BaseLabelTraceRecorder()
        let tapHandler = ImmersiveMapTapHandler(controlsRuntime: controlsRuntime,
                                                selectionHandler: selectionHandler,
                                                cameraRuntime: cameraRuntime)
        let rendererBuilder = ImmersiveMapRendererBuilder(cameraRuntime: cameraRuntime,
                                                          avatarRuntime: avatarRuntime,
                                                          markerRuntime: markerRuntime,
                                                          sceneModelRuntime: sceneModelRuntime,
                                                          renderRuntime: renderRuntime,
                                                          selectionHandler: selectionHandler,
                                                          debugOverlayControls: debugOverlayControls,
                                                          debugOverlayHUDSnapshotStore: debugOverlayHUDSnapshotStore,
                                                          tileTraceRecorder: tileTraceRecorder,
                                                          baseLabelTraceRecorder: baseLabelTraceRecorder)
        let frameRenderDelegate = ImmersiveMapFrameRenderDelegate(layer: layer,
                                                                  renderRuntime: renderRuntime,
                                                                  viewportRuntime: viewportRuntime,
                                                                  cameraAnimationRuntime: cameraAnimationRuntime)

        self.gestureController = gestureController
        self.renderRuntime = renderRuntime
        self.viewportRuntime = viewportRuntime
        self.avatarRuntime = avatarRuntime
        self.markerRuntime = markerRuntime
        self.sceneModelRuntime = sceneModelRuntime
        self.controlsRuntime = controlsRuntime
        self.cameraRuntime = cameraRuntime
        self.interactionRuntime = interactionRuntime
        self.cameraAnimationRuntime = cameraAnimationRuntime
        self.cameraCommandHandler = cameraCommandHandler
        self.selectionHandler = selectionHandler
        self.debugOverlayControls = debugOverlayControls
        self.debugOverlayHUDSnapshotStore = debugOverlayHUDSnapshotStore
        self.tileTraceRecorder = tileTraceRecorder
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.mapView = mapView
        self.tapHandler = tapHandler
        self.rendererBuilder = rendererBuilder
        self.frameRenderDelegate = frameRenderDelegate
    }

    /// Installs the debug panel over the map, once: a host view keeps the
    /// first panel it is given, as it keeps its layer. Returns the panel's
    /// runtime, nil when one is installed already or the view is gone.
    @discardableResult
    func installDebugPanel(_ panel: ImmersiveMapDebugPanel) -> (any ImmersiveMapDebugPanelRuntime)? {
        guard debugPanelRuntime == nil, let mapView else {
            return nil
        }
        let host = ImmersiveMapDebugPanelHost(mapView: mapView,
                                              controls: debugOverlayControls,
                                              hudSnapshotStore: debugOverlayHUDSnapshotStore,
                                              tileTraceRecorder: tileTraceRecorder,
                                              baseLabelTraceRecorder: baseLabelTraceRecorder,
                                              renderRuntime: renderRuntime,
                                              cameraRuntime: cameraRuntime,
                                              cameraAnimationRuntime: cameraAnimationRuntime)
        let runtime = panel.makeRuntime(host)
        debugPanelRuntime = runtime
        return runtime
    }
}
