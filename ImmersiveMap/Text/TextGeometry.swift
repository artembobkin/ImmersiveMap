// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

struct TextSize {
    let width: simd_float1
    let height: simd_float1
}

struct TextMetrics {
    let size: TextSize
    let vertices: [LabelVertex]
}

enum LabelTextAlignment {
    case left
    case center
    case right
}

struct LabelWrapOptions {
    let maxWidthPx: Float
    let maxLines: Int
    let alignment: LabelTextAlignment

    init(maxWidthPx: Float,
         maxLines: Int,
         alignment: LabelTextAlignment = .left) {
        self.maxWidthPx = maxWidthPx
        self.maxLines = maxLines
        self.alignment = alignment
    }
}

/// CPU mirror of the screen-text vertex in `Render/Text/Shaders/TextShader.metal`.
struct TextVertex {
    var position: SIMD4<Float> // x, y, z=0, w=1
    var uv: SIMD2<Float>
}

/// CPU mirror of the label vertex in `Render/Text/Shaders/TextShader.metal`.
struct LabelVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var labelIndex: simd_int1
    var spriteUV: SIMD2<Float>

    init(position: SIMD2<Float>,
         uv: SIMD2<Float>,
         labelIndex: simd_int1,
         spriteUV: SIMD2<Float> = .zero) {
        self.position = position
        self.uv = uv
        self.labelIndex = labelIndex
        self.spriteUV = spriteUV
    }
}

/// One string to lay out at a screen position.
struct TextEntry {
    let text: String
    let position: SIMD2<Float>
    let scale: Float

    init(text: String, position: SIMD2<Float>, scale: Float = 1.0) {
        self.text = text
        self.position = position
        self.scale = scale
    }
}
