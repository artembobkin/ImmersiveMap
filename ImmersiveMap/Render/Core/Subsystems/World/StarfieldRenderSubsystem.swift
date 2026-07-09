// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class StarfieldRenderSubsystem: RenderSubsystem {
    let name: String = "Starfield"

    private let starfieldRenderer: StarfieldRenderer

    init(starfieldRenderer: StarfieldRenderer) {
        self.starfieldRenderer = starfieldRenderer
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .starfield,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        starfieldRenderer.draw(renderEncoder: encoder,
                               globe: frameContext.globeRenderUniform,
                               earthScene: frameContext.earthSceneUniform,
                               cameraView: frameContext.cameraMatrices.view,
                               cameraEye: frameContext.cameraEye,
                               drawSize: frameContext.drawSize,
                               nowTime: Float(frameContext.time))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
