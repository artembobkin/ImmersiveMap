// Copyright (c) 2025-2026 Artem Bobkin.
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
    // Глиф размещён экстраполяцией за концы пути - рисуется, но в коллизионные
    // кандидаты не попадает (см. roadLabelPlacementKernel).
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
    let distanceAlongPath: Float
    let anchorOrdinal: UInt32
    let _padding: UInt32 = 0
}
