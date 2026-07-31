// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Receives renderer-pipeline events and forwards them to the owners of the map's runtime state.
/// Does not own the renderer and makes no frame decisions; it only connects render events
/// to `ImmersiveMapRenderRuntime` and the selection runtime.
/// Thread-safe: weak references are written only in init; the recipients are
/// themselves thread-safe or receive events via a hop to the main actor.
final class ImmersiveMapRenderEventSink: RenderFrameEventSink, @unchecked Sendable {
    private weak var renderRuntime: ImmersiveMapRenderRuntime?
    private weak var selectionHandler: ImmersiveMapSelectionHandler?
    private weak var markerRuntime: ImmersiveMapMarkerRuntime?
    private let debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore

    init(renderRuntime: ImmersiveMapRenderRuntime,
         selectionHandler: ImmersiveMapSelectionHandler,
         markerRuntime: ImmersiveMapMarkerRuntime,
         debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore) {
        self.renderRuntime = renderRuntime
        self.selectionHandler = selectionHandler
        self.markerRuntime = markerRuntime
        self.debugOverlayHUDSnapshotStore = debugOverlayHUDSnapshotStore
    }

    func invalidate(_ reason: RenderInvalidationReason) {
        renderRuntime?.requestFrame(reason: reason)
    }

    func applyActivityState(_ state: RenderActivityState) {
        renderRuntime?.applyRenderActivityState(state)
    }

    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {
        Task { @MainActor [weak selectionHandler] in
            selectionHandler?.updateAvatarSelectionSnapshot(snapshot)
        }
    }

    func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?) {
        debugOverlayHUDSnapshotStore.publish(snapshot)
    }

    func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot) {
        // The only caller: RenderFrameEngine.renderFrame on the main thread
        // (display link in the main runloop). No hop: the snapshot must apply
        // in the same CA transaction as this frame's present.
        MainActor.assumeIsolated {
            markerRuntime?.apply(snapshot)
        }
    }
}
