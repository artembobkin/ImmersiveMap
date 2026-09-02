// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The atmosphere around the globe's limb. Drawn in the world pass right
/// after the globe surface and the polar caps, with depth off: the halo
/// falls off into space and the rim glow decays inward over the surface,
/// both shaped analytically from the view ray (nothing on the sphere writes
/// depth it could test against). The layer follows the starfield's rule:
/// transparent space leaves everything around the globe unpainted, the
/// atmosphere included (`RenderLayerPlanner` gates both on the same flag).
final class AtmosphereRenderSubsystem: RenderSubsystem {
    let name: String = "Atmosphere"

    private let atmosphereRenderer: AtmosphereRenderer
    private let depthDisabledState: MTLDepthStencilState

    init(atmosphereRenderer: AtmosphereRenderer,
         depthDisabledState: MTLDepthStencilState) {
        self.atmosphereRenderer = atmosphereRenderer
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .atmosphere,
              frameContext.renderSurfaceMode == .spherical,
              // The atmosphere hugs the limb: with the planet filling the
              // whole viewport there is neither halo nor rim on screen.
              StarfieldRenderSubsystem.frameShowsSky(frameContext: frameContext) else {
            return
        }
        // Depth off explicitly: the rim glow paints over the ground, whose
        // opaque layers wrote their rank depth at the far plane.
        encoder.setDepthStencilState(depthDisabledState)
        let uniform = AtmosphereUniform.make(globe: frameContext.globeRenderUniform,
                                             projectionView: frameContext.cameraMatrices.projectionView,
                                             cameraEye: frameContext.cameraEye)
        atmosphereRenderer.draw(renderEncoder: encoder, uniform: uniform)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
