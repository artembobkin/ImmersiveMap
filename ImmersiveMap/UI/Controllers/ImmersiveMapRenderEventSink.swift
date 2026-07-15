// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Принимает события renderer-пайплайна и передает их владельцам runtime-состояния карты.
/// Не владеет renderer и не принимает решений о кадре; только связывает render events
/// с `ImmersiveMapRenderRuntime` и selection runtime.
/// Потокобезопасен: weak-ссылки записываются только в init, адресаты сами
/// потокобезопасны либо получают события через hop на main actor.
final class ImmersiveMapRenderEventSink: RenderFrameEventSink, @unchecked Sendable {
    private weak var renderRuntime: ImmersiveMapRenderRuntime?
    private weak var selectionHandler: ImmersiveMapSelectionHandler?
    private let debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore

    init(renderRuntime: ImmersiveMapRenderRuntime,
         selectionHandler: ImmersiveMapSelectionHandler,
         debugOverlayHUDSnapshotStore: DebugOverlayHUDSnapshotStore) {
        self.renderRuntime = renderRuntime
        self.selectionHandler = selectionHandler
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
}
