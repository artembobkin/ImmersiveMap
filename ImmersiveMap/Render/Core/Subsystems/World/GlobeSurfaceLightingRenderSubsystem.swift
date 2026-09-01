// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Lights the globe surface once per pixel, right after the unlit ground
/// layers blended and before the sky. The fragment resolves the pixel's
/// place on the sphere from the view ray and hands the blend state the
/// affine light (multiply in alpha, add in rgb); the `greater` depth test
/// at the far plane keeps the draw to exactly the pixels the placeholder
/// grid wrote its depth to, so space is untouched and the polar caps, which
/// write no depth and light themselves inline, draw after as always.
///
/// Draws nothing whenever `GlobeSurfaceLightingPath` says the lighting is
/// not affine this frame; the ground layers then light themselves inline,
/// as they always did.
final class GlobeSurfaceLightingRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeSurfaceLighting"

    private let pipeline: GlobeSurfaceLightingPipeline
    private let surfaceLightingDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    init(pipeline: GlobeSurfaceLightingPipeline,
         surfaceLightingDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.pipeline = pipeline
        self.surfaceLightingDepthState = surfaceLightingDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeSurfaceLighting,
              frameContext.renderSurfaceMode == .spherical,
              GlobeSurfaceLightingPath.isDeferred(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                  transition: frameContext.globeRenderUniform.transition) else {
            return
        }

        var uniform = GlobeSurfaceLightingUniform.make(globe: frameContext.globeRenderUniform,
                                                       earthScene: frameContext.earthSceneUniform,
                                                       projectionView: frameContext.cameraMatrices.projectionView,
                                                       cameraEye: frameContext.cameraEye)
        var earthScene = frameContext.earthSceneUniform
        var atmosphere = GlobeAtmosphereUniform.make(settings: frameContext.services.settings.scene.atmosphere,
                                                     earthScene: frameContext.earthSceneUniform,
                                                     globe: frameContext.globeRenderUniform)
        encoder.setDepthStencilState(surfaceLightingDepthState)
        pipeline.selectPipeline(renderEncoder: encoder)
        encoder.setCullMode(.none)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<GlobeSurfaceLightingUniform>.stride, index: 0)
        encoder.setFragmentBytes(&earthScene, length: MemoryLayout<EarthSceneUniform>.stride, index: 1)
        encoder.setFragmentBytes(&atmosphere, length: MemoryLayout<GlobeAtmosphereUniform>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
