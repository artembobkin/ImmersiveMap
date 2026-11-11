// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Owns the layers controller attached to a single map view runtime.
/// Asks for a frame when the app changes its layers and feeds them to the
/// renderer.
@MainActor
final class ImmersiveMapLayerRuntime: @preconcurrency LayerRenderSource {
    private weak var controller: ImmersiveMapLayersController?

    var currentLayers: [ImmersiveMapLayer] {
        controller?.layers ?? []
    }

    func attachController(_ newController: ImmersiveMapLayersController?,
                          renderRuntime: ImmersiveMapRenderRuntime) {
        guard controller !== newController else {
            return
        }

        controller?.clearChangeHandler(ownedBy: self)
        controller = newController
        newController?.setChangeHandler({ [weak renderRuntime] in
            renderRuntime?.requestFrame()
        }, owner: self)
        renderRuntime.requestFrame()
    }

    func detachController() {
        controller?.clearChangeHandler(ownedBy: self)
        controller = nil
    }
}
