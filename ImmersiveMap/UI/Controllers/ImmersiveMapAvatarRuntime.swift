// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Владеет avatar controller, подключенным к одному map view runtime.
/// Связывает avatar mutations с selection/render runtimes и отдает avatar data в renderer.
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

        controller?.setChangeHandler(nil)
        controller = newController
        newController?.setChangeHandler { [weak selectionHandler, weak renderRuntime] in
            selectionHandler?.handleAvatarControllerDidChange()
            renderRuntime?.requestFrame()
        }
        newController?.markSnapshotDirty()
        selectionHandler.syncSelectionWithAvailableMapObjects()
        renderRuntime.requestFrame()
    }

    func detachController() {
        controller?.setChangeHandler(nil)
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
