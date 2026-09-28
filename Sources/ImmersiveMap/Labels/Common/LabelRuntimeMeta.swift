// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LabelRuntimeMeta.swift
//  ImmersiveMap
//

struct LabelRuntimeMeta {
    var duplicate: UInt8
    var _padding0: UInt8 = 0
    var _padding: UInt16 = 0
    var visibleTileIndex: UInt32
    var fadeAlpha: Float = 0
    /// How much the label is shrunk for its distance
    /// (`BaseSettings.perspectiveMinimumScale`): 1 at the camera's focus and
    /// nearer, less toward the horizon. The base label shaders scale the
    /// whole label by it. The road labels leave it at 1 and never read it.
    var perspectiveScale: Float = 1
    /// Collision box in layout points; the label shaders scale it with the
    /// frame's pixels-per-point alongside the glyph geometry.
    var labelSizePoints: SIMD2<Float> = .zero
}
