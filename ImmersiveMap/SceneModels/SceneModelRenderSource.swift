// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A request to fly a model along a path, collected by the public controller
/// and started by the presentation store on the frame that applies it.
struct SceneModelPathAnimationRequest {
    let path: ImmersiveMapGeoPath
    let duration: TimeInterval
    let curve: ImmersiveMapPathAnimationCurve
    let appliesHeading: Bool
    let appliesPitch: Bool
}

/// Snapshot of scene model mutations collected by the public controller and
/// consumed destructively by the render subsystem.
struct SceneModelsSnapshot {
    let models: [ImmersiveMapSceneModel]
    /// Duration of the transform (orientation/scale/altitude) animation
    /// requested for a model in this snapshot; absent means snap.
    let transformAnimationDurationsById: [UInt64: TimeInterval]
    /// Path animations started in this snapshot.
    let pathAnimationsById: [UInt64: SceneModelPathAnimationRequest]
    /// Path animations the app cancelled; the store drops them without
    /// touching the model's displayed transform.
    let cancelledPathAnimationIds: [UInt64]
    let removedIds: [UInt64]
    let version: UInt64

    init(models: [ImmersiveMapSceneModel],
         transformAnimationDurationsById: [UInt64: TimeInterval],
         pathAnimationsById: [UInt64: SceneModelPathAnimationRequest] = [:],
         cancelledPathAnimationIds: [UInt64] = [],
         removedIds: [UInt64],
         version: UInt64) {
        self.models = models
        self.transformAnimationDurationsById = transformAnimationDurationsById
        self.pathAnimationsById = pathAnimationsById
        self.cancelledPathAnimationIds = cancelledPathAnimationIds
        self.removedIds = removedIds
        self.version = version
    }
}

/// The single seam between the renderer and UI-side scene model ownership.
protocol SceneModelRenderSource: AnyObject {
    var currentSceneModelsController: ImmersiveMapSceneModelsController? { get }
}
