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
    private weak var sceneModelRuntime: ImmersiveMapSceneModelRuntime?
    private let debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore
    // Written and read on the main actor only (invalidateDelivery from the
    // teardown paths, the guard inside the delivery hop).
    nonisolated(unsafe) private var isDeliveryInvalidated = false

    init(renderRuntime: ImmersiveMapRenderRuntime,
         selectionHandler: ImmersiveMapSelectionHandler,
         markerRuntime: ImmersiveMapMarkerRuntime,
         sceneModelRuntime: ImmersiveMapSceneModelRuntime,
         debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore) {
        self.renderRuntime = renderRuntime
        self.selectionHandler = selectionHandler
        self.markerRuntime = markerRuntime
        self.sceneModelRuntime = sceneModelRuntime
        self.debugOverlayHUDSnapshotStore = debugOverlayHUDSnapshotStore
    }

    func invalidate(_ reason: RenderInvalidationReason) {
        renderRuntime?.requestFrame(reason: reason)
    }

    func applyActivityState(_ state: RenderActivityState) {
        renderRuntime?.applyRenderActivityState(state)
    }

    /// Cuts snapshot delivery when the engine feeding this sink is discarded.
    /// An in-flight frame's GPU completion can land after a renderer
    /// recreation; its snapshot carries the OLD engine's high frame index and
    /// would win the monotonic guard against the successor's reset state.
    /// Call on the main thread (every discard path runs there: recreation,
    /// pool drop, export teardown).
    func invalidateDelivery() {
        isDeliveryInvalidated = true
    }

    /// Same guarded main-actor hop as the selection snapshot: a discarded
    /// engine's late frame must not fire a completion the teardown already
    /// resolved with `false`.
    func completeSceneModelPathAnimations(_ results: [SceneModelPathAnimationResult]) {
        Task { @MainActor [weak sceneModelRuntime, self] in
            guard self.isDeliveryInvalidated == false else {
                return
            }
            sceneModelRuntime?.applyPathAnimationResults(results)
        }
    }

    func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {
        Task { @MainActor [weak selectionHandler, self] in
            guard self.isDeliveryInvalidated == false else {
                return
            }
            selectionHandler?.updateAvatarSelectionSnapshot(snapshot)
        }
    }

    func updateSceneModelSelectionSnapshot(_ snapshot: SceneModelSelectionSnapshot) {
        Task { @MainActor [weak selectionHandler, self] in
            guard self.isDeliveryInvalidated == false else {
                return
            }
            selectionHandler?.updateSceneModelSelectionSnapshot(snapshot)
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
