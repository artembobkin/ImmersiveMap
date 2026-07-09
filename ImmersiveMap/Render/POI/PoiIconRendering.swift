// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  PoiIconRendering.swift
//  ImmersiveMap
//

import simd

struct PoiIconStyleUniform {
    var backgroundColor: SIMD4<Float>
    var iconColor: SIMD4<Float>

    init(backgroundColor: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
         iconColor: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)) {
        self.backgroundColor = backgroundColor
        self.iconColor = iconColor
    }
}
