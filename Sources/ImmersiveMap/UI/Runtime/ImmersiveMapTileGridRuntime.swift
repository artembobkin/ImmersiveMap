// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Owns the tile grid's controller attached to a single map view runtime.
/// Asks for a frame when the app or a tap changes the grid, and hands the
/// controller's side of it to the renderer and to the tap.
@MainActor
final class ImmersiveMapTileGridRuntime: @preconcurrency TileGridRenderSource, TileGridSelectionSource {
    private weak var controller: ImmersiveMapTileGridController?

    var tileGridContent: TileGridContent? {
        controller?.content
    }

    var tileGridController: ImmersiveMapTileGridController? {
        controller
    }

    func attachController(_ newController: ImmersiveMapTileGridController?,
                          renderRuntime: ImmersiveMapRenderRuntime) {
        guard controller !== newController else {
            return
        }

        controller?.clearChangeHandler(ownedBy: self)
        controller = newController
        // The app changes the selection from any thread: the frame is
        // asked for from there.
        newController?.setChangeHandler({ [weak renderRuntime] in
            renderRuntime?.requestFrame()
        }, owner: self)
        // Attached or detached, the grid appears or goes.
        renderRuntime.requestFrame()
    }

    func detachController() {
        controller?.clearChangeHandler(ownedBy: self)
        controller = nil
    }
}
