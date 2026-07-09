// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class PostProcessingRenderSubsystem: RenderSubsystem {
    let name: String = "PostProcessing"

    private let fxaaPipeline: FXAAPipeline
    private let inputTextureProvider: () -> MTLTexture?

    init(fxaaPipeline: FXAAPipeline,
         inputTextureProvider: @escaping () -> MTLTexture?) {
        self.fxaaPipeline = fxaaPipeline
        self.inputTextureProvider = inputTextureProvider
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .postProcessing,
              let inputTexture = inputTextureProvider() else {
            return
        }

        fxaaPipeline.draw(renderEncoder: encoder,
                          sourceTexture: inputTexture,
                          drawSize: frameContext.drawSize,
                          isEnabled: frameContext.services.settings.postProcessing.fxaaEnabled)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
