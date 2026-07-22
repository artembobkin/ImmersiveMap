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

final class FrameContextSharedState {
    var tilePlacementState: TilePlacementState = .empty
    var placeTileTrackingState: PlaceTileTrackingState = .empty
    var tileProjectionIndexState: TileProjectionIndexState = .empty
    var tileAtlasDebugSummary: TileAtlasDebugSummary?
    var baseLabelState: BaseLabelState = .empty
    var roadLabelState: RoadLabelState = .empty
    var avatarState: AvatarState = .empty
}
