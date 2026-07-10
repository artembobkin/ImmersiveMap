// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import QuartzCore

/// Собирает `RenderFrameEngine` из текущего runtime graph.
/// Создает render camera и связывает renderer dependencies, не раскрывая детали сборки во view.
final class ImmersiveMapRendererBuilder {
    private let cameraRuntime: ImmersiveMapCameraRuntime
    private let avatarRuntime: ImmersiveMapAvatarRuntime
    private let renderRuntime: ImmersiveMapRenderRuntime
    private let selectionHandler: ImmersiveMapSelectionHandler
    private let debugOverlayControls: DebugOverlayControlState
    private let debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore
    private let tileTraceRecorder: TileTraceRecorder
    private let baseLabelTraceRecorder: BaseLabelTraceRecorder

    init(cameraRuntime: ImmersiveMapCameraRuntime,
         avatarRuntime: ImmersiveMapAvatarRuntime,
         renderRuntime: ImmersiveMapRenderRuntime,
         selectionHandler: ImmersiveMapSelectionHandler,
         debugOverlayControls: DebugOverlayControlState,
         debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore,
         tileTraceRecorder: TileTraceRecorder,
         baseLabelTraceRecorder: BaseLabelTraceRecorder) {
        self.cameraRuntime = cameraRuntime
        self.avatarRuntime = avatarRuntime
        self.renderRuntime = renderRuntime
        self.selectionHandler = selectionHandler
        self.debugOverlayControls = debugOverlayControls
        self.debugOverlayHUDSnapshotStore = debugOverlayHUDSnapshotStore
        self.tileTraceRecorder = tileTraceRecorder
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
    }

    func makeRenderer(layer: CAMetalLayer,
                      settings: ImmersiveMapSettings,
                      cameraPosition: ImmersiveMapCameraPosition?) -> RenderFrameEngine {
        let renderCamera = cameraRuntime.makeRenderCamera(settings: settings,
                                                          cameraPosition: cameraPosition)
        let eventSink = ImmersiveMapRenderEventSink(renderRuntime: renderRuntime,
                                                    selectionHandler: selectionHandler,
                                                    debugOverlayHUDSnapshotStore: debugOverlayHUDSnapshotStore)
        let providerRuntime = ImmersiveMapProviderRuntimeContext(settings: settings)
        return RenderFrameEngine(layer: layer,
                                 avatarSource: avatarRuntime,
                                 providerRuntime: providerRuntime,
                                 settings: settings,
                                 debugOverlayControls: debugOverlayControls,
                                 renderCamera: renderCamera,
                                 presentationStateResolver: cameraRuntime.presentationStateResolver,
                                 eventSink: eventSink,
                                 tileTraceRecorder: tileTraceRecorder,
                                 baseLabelTraceRecorder: baseLabelTraceRecorder)
    }
}
