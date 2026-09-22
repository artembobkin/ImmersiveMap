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

struct RoadPathRangeGpu {
    let start: UInt32
    let count: UInt32
    let _padding0: UInt32 = 0
    let _padding1: UInt32 = 0
}

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

struct RoadGlyphPlacementOutput {
    var position: SIMD2<Float>
    var angle: Float
    var visible: UInt32
    // Glyph placed by extrapolation beyond the path ends - it is drawn, but
    // does not become a collision candidate (see roadLabelPlacementKernel).
    var extrapolated: UInt32
}

struct RoadGlyphCollisionOutput {
    let halfSizeAABB: SIMD2<Float>
    let _padding: SIMD2<Float> = .zero
}

struct RoadLabelAnchor {
    let pathIndex: UInt32
    let segmentIndex: UInt32
    let t: Float
    let anchorOrdinal: UInt32
}

// GPU mirror of the Metal RoadLabelAnchor (RoadLabelCommon.h). The placement
// kernel reads the anchor's screen position from its own projected path point
// at `pointIndex` instead of re-deriving it from `t`: a screen-space lerp is
// not the projection of the world-space anchor under a tilted camera.
struct RoadLabelAnchorGpu {
    let pathIndex: UInt32
    let segmentIndex: UInt32
    let pointIndex: UInt32
    let _padding: UInt32 = 0
}
