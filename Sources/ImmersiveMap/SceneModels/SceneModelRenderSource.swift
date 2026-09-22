// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A request to fly a model along a path, collected by the public controller
/// and started by the presentation store on the frame that applies it.
struct SceneModelPathAnimationRequest {
    /// Distinguishes this request from a later `animate` for the same id, so a
    /// result that arrives after a supersede cannot resolve the new animation.
    let generation: UInt64
    let path: ImmersiveMapGeoPath
    let duration: TimeInterval
    let curve: ImmersiveMapPathAnimationCurve
    let appliesHeading: Bool
    let appliesPitch: Bool
}

/// Where a path animation left the model, reported back so the controller's
/// descriptor keeps telling the truth: a cancelled animation stops partway, and
/// nothing else knows where that is.
struct SceneModelPathAnimationResult {
    let id: UInt64
    let generation: UInt64
    /// true when the model reached the end of the path.
    let finished: Bool
    let coordinate: GeoCoordinate
    let altitudeMeters: Double
    let headingDegrees: Double
    let pitchDegrees: Double
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
