// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// CPU mirror of the fragment-side text style in
/// `Render/Text/Shaders/TextShader.metal`: fill color plus the halo drawn around
/// the glyph so labels stay readable over the map.
struct TextStyleUniform: Equatable {
    var textColor: SIMD3<Float>
    var _padding0: Float = 0.0
    var strokeColor: SIMD3<Float>
    var strokeWidthPx: Float

    init(textColor: SIMD3<Float>,
         strokeColor: SIMD3<Float> = SIMD3<Float>(1.0, 1.0, 1.0),
         strokeWidthPx: Float = 2.0) {
        self.textColor = textColor
        self.strokeColor = strokeColor
        self.strokeWidthPx = strokeWidthPx
    }
}
