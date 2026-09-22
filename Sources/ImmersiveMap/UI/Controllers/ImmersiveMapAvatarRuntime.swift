// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Owns the avatar controller attached to a single map view runtime.
/// Bridges avatar mutations to the selection/render runtimes and feeds avatar data to the renderer.
@MainActor
final class ImmersiveMapAvatarRuntime: @preconcurrency AvatarRenderSource {
    private weak var controller: ImmersiveMapAvatarsController?

    var currentAvatarController: ImmersiveMapAvatarsController? {
        controller
    }

    func isAttachedController(_ avatarsController: ImmersiveMapAvatarsController?) -> Bool {
        controller === avatarsController
    }

    func attachController(_ newController: ImmersiveMapAvatarsController?,
                          selectionHandler: ImmersiveMapSelectionHandler,
                          renderRuntime: ImmersiveMapRenderRuntime) {
        guard controller !== newController else {
            return
        }

        controller?.clearChangeHandler(ownedBy: self)
        controller = newController
        newController?.setChangeHandler({ [weak selectionHandler, weak renderRuntime] in
            selectionHandler?.handleAvatarControllerDidChange()
            renderRuntime?.requestFrame()
        }, owner: self)
        newController?.markSnapshotDirty()
        selectionHandler.syncSelectionWithAvailableMapObjects()
        renderRuntime.requestFrame()
    }

    func detachController() {
        controller?.clearChangeHandler(ownedBy: self)
        controller = nil
    }

    func markSnapshotDirty() {
        controller?.markSnapshotDirty()
    }

    func marker(id: UInt64) -> AvatarMarker? {
        controller?.marker(id: id)
    }

    func updateMarkerSelection(id: UInt64,
                               isSelected: Bool) {
        controller?.update(id: id,
                           isSelected: isSelected)
    }
}
