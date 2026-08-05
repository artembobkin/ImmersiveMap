// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  FrameContextSharedState.swift
//  ImmersiveMap
//

import Metal

struct BaseLabelState {
    nonisolated(unsafe) static let empty = BaseLabelState(labelInputsCount: 0,
                                      activeLabelSpanCount: 0,
                                      labelRuntimeMetaBuffer: nil,
                                      screenPositionsBuffer: nil,
                                      baseLabelsDrawBatches: [],
                                      hasActiveFadeAnimations: false,
                                      hasActiveVisibilityCycle: false)

    var labelInputsCount: Int
    var activeLabelSpanCount: Int
    var labelRuntimeMetaBuffer: MTLBuffer?
    var screenPositionsBuffer: MTLBuffer?
    var baseLabelsDrawBatches: [BaseLabelDrawBatch]
    var hasActiveFadeAnimations: Bool
    var hasActiveVisibilityCycle: Bool
}

/// Debug frame of one base label in screen pixels: the collision AABB and the
/// current visibility (labels hidden by collision/horizon still participate in
/// the frame and must show up in the overlay).
struct BaseLabelDebugBox {
    let center: SIMD2<Float>
    let halfSize: SIMD2<Float>
    let isVisible: Bool
}

/// Snapshot of label frames for the debug overlay. Populated only when the
/// HUD toggle is on, otherwise empty and free. Road frames go in a separate
/// list (one frame per glyph): they take part in the same collision solver
/// but are drawn in their own color to stand apart from the base ones.
struct BaseLabelDebugBoxesState {
    nonisolated(unsafe) static let empty = BaseLabelDebugBoxesState(boxes: [], roadBoxes: [])

    let boxes: [BaseLabelDebugBox]
    let roadBoxes: [BaseLabelDebugBox]
}

struct RoadLabelState {
    nonisolated(unsafe) static let empty = RoadLabelState(instanceCount: 0,
                                      glyphCount: 0,
                                      activeRoadLabelTiles: [],
                                      runtimeMetaBuffer: nil,
                                      placementBuffer: nil,
                                      glyphInputBuffer: nil,
                                      glyphVerticesBuffer: nil,
                                      glyphVertexCount: 0,
                                      drawLabels: [],
                                      hasActiveFadeAnimations: false)

    var instanceCount: Int
    var glyphCount: Int
    var activeRoadLabelTiles: [VisibleTile]
    var runtimeMetaBuffer: MTLBuffer?
    var placementBuffer: MTLBuffer?
    var glyphInputBuffer: MTLBuffer?
    var glyphVerticesBuffer: MTLBuffer?
    var glyphVertexCount: Int
    var drawLabels: [DrawRoadLabels]
    var hasActiveFadeAnimations: Bool
}

struct AvatarState {
    static let empty = AvatarState(hasActiveAnimations: false,
                                   selectionSnapshot: .empty)

    var hasActiveAnimations: Bool
    var selectionSnapshot: AvatarSelectionSnapshot
}

struct SceneModelFrameState {
    static let empty = SceneModelFrameState(hasActiveAnimations: false,
                                            hasShadowCasters: false,
                                            pathAnimationResults: [])

    var hasActiveAnimations: Bool
    /// At least one model survived light-frustum culling this frame; feeds the
    /// shadow-pass gate together with the building-caster check.
    var hasShadowCasters: Bool
    /// Path animations that ended on this frame, with the transform they left
    /// the model at; the engine forwards them so the controller's descriptor
    /// stays truthful and the app's completion fires exactly once.
    var pathAnimationResults: [SceneModelPathAnimationResult]
}

struct RouteFrameState {
    static let empty = RouteFrameState(hasActiveAnimations: false)

    var hasActiveAnimations: Bool
}

struct MarkerFrameState {
    static let empty = MarkerFrameState(snapshot: nil)

    /// nil: no markers, nothing to publish. Empty snapshot: markers exist,
    /// but all are hidden, and the UI must hide the views.
    var snapshot: MarkerProjectionSnapshot?
}

final class FrameContextSharedState {
    var tilePlacementState: TilePlacementState = .empty
    var placeTileTrackingState: PlaceTileTrackingState = .empty
    var tileProjectionIndexState: TileProjectionIndexState = .empty
    var tileAtlasDebugSummary: TileAtlasDebugSummary?
    var baseLabelState: BaseLabelState = .empty
    var baseLabelDebugBoxesState: BaseLabelDebugBoxesState = .empty
    var roadLabelState: RoadLabelState = .empty
    var avatarState: AvatarState = .empty
    var sceneModelState: SceneModelFrameState = .empty
    var routeState: RouteFrameState = .empty
    var markerState: MarkerFrameState = .empty
}
