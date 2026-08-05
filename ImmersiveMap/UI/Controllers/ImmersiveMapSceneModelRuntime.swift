// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Owns the scene models controller attached to a single map view runtime.
/// Bridges model mutations to the render runtime and feeds model data to the renderer.
@MainActor
final class ImmersiveMapSceneModelRuntime: @preconcurrency SceneModelRenderSource {
    private weak var controller: ImmersiveMapSceneModelsController?

    var currentSceneModelsController: ImmersiveMapSceneModelsController? {
        controller
    }

    func isAttachedController(_ sceneModelsController: ImmersiveMapSceneModelsController?) -> Bool {
        controller === sceneModelsController
    }

    func attachController(_ newController: ImmersiveMapSceneModelsController?,
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

    func applyPathAnimationResults(_ results: [SceneModelPathAnimationResult]) {
        controller?.applyPathAnimationResults(results)
    }

    func cancelAllPathAnimations() {
        controller?.cancelAllPathAnimations()
    }

    func markSnapshotDirty() {
        controller?.markSnapshotDirty()
    }
}
