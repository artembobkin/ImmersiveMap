// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Owns the pin controller attached to a single map view runtime.
/// Bridges pin mutations to the selection/render runtimes and feeds pin data to the renderer.
@MainActor
final class ImmersiveMapPinRuntime: @preconcurrency PinRenderSource, PinSelectionSource {
    private weak var controller: ImmersiveMapPinsController?

    var currentPinController: ImmersiveMapPinsController? {
        controller
    }

    func isAttachedController(_ pinsController: ImmersiveMapPinsController?) -> Bool {
        controller === pinsController
    }

    func attachController(_ newController: ImmersiveMapPinsController?,
                          selectionHandler: ImmersiveMapSelectionHandler,
                          renderRuntime: ImmersiveMapRenderRuntime) {
        guard controller !== newController else {
            return
        }

        controller?.clearChangeHandler(ownedBy: self)
        controller = newController
        newController?.setChangeHandler({ [weak selectionHandler, weak renderRuntime] in
            selectionHandler?.handleFeatureDidChange()
            renderRuntime?.requestFrame()
        }, owner: self)
        newController?.markSnapshotDirty()
        selectionHandler.syncSelectionWithAvailableObjects()
        renderRuntime.requestFrame()
    }

    func detachController() {
        controller?.clearChangeHandler(ownedBy: self)
        controller = nil
    }

    func markSnapshotDirty() {
        controller?.markSnapshotDirty()
    }

    func pin(id: UInt64) -> ImmersiveMapPin? {
        controller?.pin(id: id)
    }

    func updatePinSelection(id: UInt64,
                               isSelected: Bool) {
        controller?.update(id: id,
                           isSelected: isSelected)
    }
}
