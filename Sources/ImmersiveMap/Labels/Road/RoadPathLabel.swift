// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct RoadPathLabel {
    let text: String
    let key: UInt64
}

struct RoadPathRange {
    let start: Int
    let count: Int
    let labelIndex: Int
}

struct RoadLabelAnchorRange {
    let start: Int
    let count: Int
}

/// One glyph of a road label as the road text vertex shader reads it
/// (`RoadGlyphInput` in RoadLabelCommon.h): which instance it belongs to
/// and where it sits in the label's layout, in points. Built once per tile
/// record and uploaded once. The CPU placement reads the same array.
struct RoadGlyphInput {
    let pathIndex: UInt32
    let instanceIndex: UInt32
    let labelInstanceIndex: UInt32
    let _padding: UInt32 = 0
    let glyphCenter: Float
    let labelCenterY: Float
    let labelWidth: Float
    let spacing: Float
    let minLength: Float
}

/// Where a glyph is drawn this frame, in device pixels, as the road text
/// vertex shader reads it (`RoadGlyphPlacementOutput` in
/// RoadLabelCommon.h). Written by `RoadLabelPlacer` on the CPU and uploaded
/// per frame slot.
struct RoadGlyphPlacementOutput {
    var position: SIMD2<Float>
    var angle: Float
    var visible: UInt32

    static let hidden = RoadGlyphPlacementOutput(position: .zero, angle: 0, visible: 0)
}

/// An anchor of a road label in the tile's data: the segment of its path
/// and the parameter along it, and its ordinal among the label's anchors.
struct RoadLabelAnchor {
    let pathIndex: UInt32
    let segmentIndex: UInt32
    let t: Float
    let anchorOrdinal: UInt32
}
