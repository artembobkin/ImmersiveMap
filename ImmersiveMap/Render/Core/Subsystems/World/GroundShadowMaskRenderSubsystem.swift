// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Encodes the ground shadow mask pass of the flat presentation: a fullscreen
/// triangle that samples the shadow cascades once per pixel on the ground
/// plane. Runs only when the shadow pass ran this frame (same gate, so the
/// mask and the map can never disagree); the ground layers then read the
/// mask instead of sampling the cascades in every blended layer.
final class GroundShadowMaskRenderSubsystem: RenderSubsystem {
    let name: String = "GroundShadowMask"

    private let pipeline: GroundShadowMaskPipeline
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?

    init(pipeline: GroundShadowMaskPipeline,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?) {
        self.pipeline = pipeline
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .groundShadowMask,
              frameContext.renderSurfaceMode == .flat,
              let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
              let shadowMapTexture = shadowMapTextureProvider() else {
            return
        }

        pipeline.select(renderEncoder: encoder)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.setCullMode(.none)
        // The pass rasterizes at the mask's own size; the shader maps its
        // pixel back through that size, so the rays land on the same ground
        // points the drawable's pixels would.
        let maskSize = GroundShadowMaskPipeline.maskSize(for: frameContext.drawSize)
        var maskUniform = GroundShadowMaskUniform(
            projectionView: frameContext.cameraMatrices.projectionView,
            viewportSize: SIMD2<Float>(Float(maskSize.width), Float(maskSize.height)),
            shadow: shadowState.shadowUniform
        )
        var shadowUniform = shadowState.shadowUniform
        encoder.setFragmentBytes(&maskUniform, length: MemoryLayout<GroundShadowMaskUniform>.stride, index: 0)
        encoder.setFragmentBytes(&shadowUniform, length: MemoryLayout<ShadowUniform>.stride, index: 1)
        encoder.setFragmentTexture(shadowMapTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
