// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The polar caps: the sphere beyond the Mercator edge, drawn after the tile
/// geometry in constant style colours (the north cap the palette's open
/// ocean, the south its polar ice; see ImmersiveMapBaseColors). Nothing is
/// baked: the caps are two fan draws with one colour each.
final class GlobeCapRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeCap"

    private let globeCapDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let globeCapRenderer: GlobeCapRenderer

    init(globeCapDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         globeCapRenderer: GlobeCapRenderer) {
        self.globeCapDepthState = globeCapDepthState
        self.depthDisabledState = depthDisabledState
        self.globeCapRenderer = globeCapRenderer
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
                              globeFrame: GlobeFrameConstantsUniform.make(globe: frameContext.globeRenderUniform,
                                                                          cameraMatrix: frameContext.cameraUniform.matrix),
                              globe: frameContext.globeRenderUniform)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
