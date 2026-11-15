// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

/// Owns the layers controller attached to a single map view runtime.
/// Asks for a frame when the app changes its layers and feeds them to the
/// renderer.
@MainActor
final class ImmersiveMapLayerRuntime: @preconcurrency LayerRenderSource, LayerSelectionSource {
    private weak var controller: ImmersiveMapLayersController?

    /// Whether the app listens to taps on its layers or holds a selection:
    /// the shapes of the drawn layers are then kept at hand for a tap to
    /// be tested against. Otherwise a layer needs its mesh alone, and a
    /// layer prepared before is drawn without its GeoJSON being read.
    var shapesWanted = false {
        didSet { controller?.library.shapesWanted = shapesWanted }
    }

    var currentLayers: [ImmersiveMapLayer] {
        controller?.layers ?? []
    }

    var sourceLibrary: LayerSourceLibrary? {
        controller?.library
    }

    /// The controller the map draws, for an export that draws the same.
    var currentLayersController: ImmersiveMapLayersController? {
        controller
    }

    func layer(id: String) -> ImmersiveMapLayer? {
        controller?.layer(id: id)
    }

    func attachController(_ newController: ImmersiveMapLayersController?,
                          selectionHandler: ImmersiveMapSelectionHandler,
                          renderRuntime: ImmersiveMapRenderRuntime) {
        guard controller !== newController else {
            return
        }

        controller?.clearChangeHandler(ownedBy: self)
        controller = newController
        newController?.library.shapesWanted = shapesWanted
        // The app changes its layers from any thread: the frame is asked
        // for from there, and the selection, which is the main thread's,
        // lets go of a shape whose layer is gone once it is back on it.
        newController?.setChangeHandler({ [weak selectionHandler, weak renderRuntime] in
            renderRuntime?.requestFrame()
            Task { @MainActor in
                selectionHandler?.syncSelectionWithAvailableObjects()
            }
        }, owner: self)
        selectionHandler.syncSelectionWithAvailableObjects()
        renderRuntime.requestFrame()
    }

    func detachController() {
        controller?.clearChangeHandler(ownedBy: self)
        controller = nil
    }
}
