// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class GlobeCapRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeCap"

    private let globeCapDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let globeCapRenderer: GlobeCapRenderer
    private let tilesTexture: GlobeTilesTexture

    init(globeCapDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         globeCapRenderer: GlobeCapRenderer,
         tilesTexture: GlobeTilesTexture) {
        self.globeCapDepthState = globeCapDepthState
        self.depthDisabledState = depthDisabledState
        self.globeCapRenderer = globeCapRenderer
        self.tilesTexture = tilesTexture
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeCap,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        encoder.setDepthStencilState(globeCapDepthState)
        globeCapRenderer.draw(renderEncoder: encoder,
                              cameraUniform: frameContext.cameraUniform,
                              globe: frameContext.globeRenderUniform,
                              earthScene: frameContext.earthSceneUniform,
                              tilesTexture: tilesTexture)

        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
