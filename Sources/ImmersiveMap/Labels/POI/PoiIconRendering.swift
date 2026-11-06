// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  PoiIconRendering.swift
//  ImmersiveMap
//

import simd

struct PoiIconStyleUniform: Equatable {
    var backgroundColor: SIMD4<Float>
    var iconColor: SIMD4<Float>
    /// The opacity of the plate and its icon together, 1 solid: the POI's
    /// own under the frame's factor for the POIs
    /// (`FrameContextServices.labelOpacity`). Applied to the composite, so
    /// the icon never shows the plate through it.
    var opacity: Float

    init(backgroundColor: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
         iconColor: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
         opacity: Float = 1) {
        self.backgroundColor = backgroundColor
        self.iconColor = iconColor
        self.opacity = opacity
    }
}
