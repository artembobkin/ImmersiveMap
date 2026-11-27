// Copyright (c) 2025-2026 Artem Bobkin.
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

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .postProcessing,
              let inputTexture = inputTextureProvider() else {
            return
        }

        fxaaPipeline.draw(renderEncoder: encoder,
                          sourceTexture: inputTexture,
                          drawSize: frameContext.drawSize)
    }

}
