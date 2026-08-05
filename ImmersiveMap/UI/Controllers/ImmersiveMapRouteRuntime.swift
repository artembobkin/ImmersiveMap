// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Owns the routes controller attached to a single map view runtime.
/// Bridges route mutations to the render runtime and feeds route data to the renderer.
@MainActor
final class ImmersiveMapRouteRuntime: @preconcurrency RouteRenderSource {
    private weak var controller: ImmersiveMapRoutesController?

    var currentRoutesController: ImmersiveMapRoutesController? {
        controller
    }

    func isAttachedController(_ routesController: ImmersiveMapRoutesController?) -> Bool {
        controller === routesController
    }

    func attachController(_ newController: ImmersiveMapRoutesController?,
                          renderRuntime: ImmersiveMapRenderRuntime) {
        guard controller !== newController else {
            return
        }

        controller?.clearChangeHandler(ownedBy: self)
        controller = newController
        newController?.setChangeHandler({ [weak renderRuntime] in
            renderRuntime?.requestFrame()
        }, owner: self)
        newController?.markSnapshotDirty()
        renderRuntime.requestFrame()
    }

    func detachController() {
        controller?.clearChangeHandler(ownedBy: self)
        controller = nil
    }

    func markSnapshotDirty() {
        controller?.markSnapshotDirty()
    }
}
