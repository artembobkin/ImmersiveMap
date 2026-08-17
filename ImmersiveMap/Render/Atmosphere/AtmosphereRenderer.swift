// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Draws the atmosphere halo: one fullscreen triangle whose fragment stage
/// resolves, per pixel, how far the view ray passes outside the globe and
/// paints the scattered light there. Stateless beyond the pipeline; every
/// frame's parameters arrive as one uniform.
final class AtmosphereRenderer {
    private let pipeline: AtmospherePipeline

    init(pipeline: AtmospherePipeline) {
        self.pipeline = pipeline
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              uniform: AtmosphereUniform) {
        var uniformValue = uniform
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.none)
        renderEncoder.setFragmentBytes(&uniformValue,
                                       length: MemoryLayout<AtmosphereUniform>.stride,
                                       index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
