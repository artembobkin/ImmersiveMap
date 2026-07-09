// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import QuartzCore

/// Composition root для runtime collaborators `ImmersiveMapUIView`.
/// Создает и владеет feature runtimes/controllers, затем отдает view прямые зависимости.
@MainActor
final class ImmersiveMapRuntimeGraph {
    let gestureController: MapGestureController
    let renderRuntime: ImmersiveMapRenderRuntime
    let viewportRuntime: ImmersiveMapViewportRuntime
    let avatarRuntime: ImmersiveMapAvatarRuntime
    let controlsRuntime: ImmersiveMapControlsRuntime
    let cameraRuntime: ImmersiveMapCameraRuntime
    let interactionRuntime: ImmersiveMapInteractionRuntime
    let cameraAnimationRuntime: ImmersiveMapCameraAnimationRuntime
    let cameraCommandHandler: ImmersiveMapCameraCommandHandler
    let selectionHandler: ImmersiveMapSelectionHandler
    let debugOverlayRuntime: ImmersiveMapDebugOverlayRuntime
    let tapHandler: ImmersiveMapTapHandler
    let rendererBuilder: ImmersiveMapRendererBuilder
    let frameRenderDelegate: ImmersiveMapFrameRenderDelegate

    init(mapView: ImmersiveMapUIView,
         layer: CAMetalLayer,
         settings: ImmersiveMapSettings,
         initialCameraPosition: ImmersiveMapCameraPosition?) {
        let gestureController = MapGestureController(mapView: mapView)
        let renderRuntime = ImmersiveMapRenderRuntime(configuration: settings.renderLoop)
        let viewportRuntime = ImmersiveMapViewportRuntime()
        let avatarRuntime = ImmersiveMapAvatarRuntime()
        let controlsRuntime = ImmersiveMapControlsRuntime(mapView: mapView,
                                                          mapPanGesture: gestureController.panGesture,
                                                          settings: settings)
        let cameraRuntime = ImmersiveMapCameraRuntime(settings: settings,
                                                      initialCameraPosition: initialCameraPosition,
                                                      renderRuntime: renderRuntime,
                                                      controlsRuntime: controlsRuntime)
        let interactionRuntime = ImmersiveMapInteractionRuntime(cameraRuntime: cameraRuntime,
                                                                renderRuntime: renderRuntime)
        let cameraAnimationRuntime = ImmersiveMapCameraAnimationRuntime(cameraRuntime: cameraRuntime,
                                                                        interactionRuntime: interactionRuntime,
                                                                        renderRuntime: renderRuntime)
        let cameraCommandHandler = ImmersiveMapCameraCommandHandler(cameraRuntime: cameraRuntime,
                                                                    cameraAnimationRuntime: cameraAnimationRuntime)
        let selectionHandler = ImmersiveMapSelectionHandler(avatarRuntime: avatarRuntime,
                                                            viewportRuntime: viewportRuntime,
                                                            renderRuntime: renderRuntime)
        let debugOverlayControls = DebugOverlayControlState()
        let debugOverlayHUDSnapshotStore = DebugOverlayHUDSnapshotStore()
        let tileTraceRecorder = TileTraceRecorder()
        let baseLabelTraceRecorder = BaseLabelTraceRecorder()
        let debugOverlayRuntime = ImmersiveMapDebugOverlayRuntime(mapView: mapView,
                                                                  controls: debugOverlayControls,
                                                                  hudSnapshotStore: debugOverlayHUDSnapshotStore,
                                                                  tileTraceRecorder: tileTraceRecorder,
                                                                  baseLabelTraceRecorder: baseLabelTraceRecorder,
                                                                  renderRuntime: renderRuntime,
                                                                  cameraRuntime: cameraRuntime,
                                                                  cameraAnimationRuntime: cameraAnimationRuntime)
        let tapHandler = ImmersiveMapTapHandler(controlsRuntime: controlsRuntime,
                                                selectionHandler: selectionHandler,
                                                cameraRuntime: cameraRuntime)
        let rendererBuilder = ImmersiveMapRendererBuilder(cameraRuntime: cameraRuntime,
                                                          avatarRuntime: avatarRuntime,
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
        self.controlsRuntime = controlsRuntime
        self.cameraRuntime = cameraRuntime
        self.interactionRuntime = interactionRuntime
        self.cameraAnimationRuntime = cameraAnimationRuntime
        self.cameraCommandHandler = cameraCommandHandler
        self.selectionHandler = selectionHandler
        self.debugOverlayRuntime = debugOverlayRuntime
        self.tapHandler = tapHandler
        self.rendererBuilder = rendererBuilder
        self.frameRenderDelegate = frameRenderDelegate
    }
}

#endif
