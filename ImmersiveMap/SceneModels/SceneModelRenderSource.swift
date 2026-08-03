// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Snapshot of scene model mutations collected by the public controller and
/// consumed destructively by the render subsystem.
struct SceneModelsSnapshot {
    let models: [ImmersiveMapSceneModel]
    /// Duration of the transform (orientation/scale/altitude) animation
    /// requested for a model in this snapshot; absent means snap.
    let transformAnimationDurationsById: [UInt64: TimeInterval]
    let removedIds: [UInt64]
    let version: UInt64
}

/// The single seam between the renderer and UI-side scene model ownership.
protocol SceneModelRenderSource: AnyObject {
    var currentSceneModelsController: ImmersiveMapSceneModelsController? { get }
}
