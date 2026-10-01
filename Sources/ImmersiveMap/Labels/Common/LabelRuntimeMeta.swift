// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  LabelRuntimeMeta.swift
//  ImmersiveMap
//

/// What the label shaders read per label besides its screen point, mirrored
/// by `LabelRuntimeMeta` in LabelRuntimeMeta.h: 16 bytes, uploaded whole
/// every frame.
struct LabelRuntimeMeta {
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
