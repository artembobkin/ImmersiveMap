// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LabelRuntimeMeta.swift
//  ImmersiveMap
//

struct LabelRuntimeMeta {
    var duplicate: UInt8
    var isRetained: UInt8
    var _padding: UInt16 = 0
    var visibleTileIndex: UInt32
    var fadeAlpha: Float = 0
    var _padding1: Float = 0
    /// Collision box in layout points; the label shaders scale it with the
    /// frame's pixels-per-point alongside the glyph geometry.
    var labelSizePoints: SIMD2<Float> = .zero
}
