// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// What the labels' prepare subsystem leaves for their draws this frame
/// (`FrameStateBoard`).
struct BaseLabelState {
    nonisolated(unsafe) static let empty = BaseLabelState(labelInputsCount: 0,
                                      labelRuntimeMetaBuffer: nil,
                                      screenPositionsBuffer: nil,
                                      baseLabelsDrawBatches: [],
                                      hasActiveFadeAnimations: false)

    var labelInputsCount: Int
    var labelRuntimeMetaBuffer: MTLBuffer?
    var screenPositionsBuffer: MTLBuffer?
    var baseLabelsDrawBatches: [BaseLabelDrawBatch]
    var hasActiveFadeAnimations: Bool
}

extension BaseLabelState: FrameState {
    init() {
        self = .empty
    }
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
    static let empty = BaseLabelDebugBoxesState(boxes: [], roadBoxes: [])

    let boxes: [BaseLabelDebugBox]
    let roadBoxes: [BaseLabelDebugBox]
}

extension BaseLabelDebugBoxesState: FrameState {
    init() {
        self = .empty
    }
}

/// The road labels of the frame, as their prepare leaves them for their
/// draw.
struct RoadLabelState {
    nonisolated(unsafe) static let empty = RoadLabelState(instanceCount: 0,
                                      glyphCount: 0,
                                      activeRoadLabelTiles: [],
                                      runtimeMetaBuffer: nil,
                                      drawLabels: [],
                                      hasActiveFadeAnimations: false)

    var instanceCount: Int
    var glyphCount: Int
    var activeRoadLabelTiles: [VisibleTile]
    var runtimeMetaBuffer: MTLBuffer?
    var drawLabels: [DrawRoadLabels]
    var hasActiveFadeAnimations: Bool
}

extension RoadLabelState: FrameState {
    init() {
        self = .empty
    }
}
