// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The atmosphere halo around the globe. Drawn after the globe surface and
/// the starfield in the world pass, at the far plane: the depth test drops
/// the part of it inside the silhouette, and the halo blends over the sky
/// only where space shows.
final class AtmosphereRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "Atmosphere"

    private let atmosphereRenderer: AtmosphereRenderer
    private let skyBackdropDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    init(atmosphereRenderer: AtmosphereRenderer,
         skyBackdropDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.atmosphereRenderer = atmosphereRenderer
        self.skyBackdropDepthState = skyBackdropDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext _: FrameContext) {}

    /// Whether the halo is painted.
    ///
    /// The halo lives in space, so it follows the starfield's rule: transparent
    /// space leaves everything outside the globe unpainted, halo included, and
    /// only the surface's own glow toward the limb remains. Off by setting is
    /// the other way out. An intensity of zero keeps the layer on and paints
    /// nothing, which is the same picture at a draw call's cost.
    static func isAtmosphereEnabled(settings: ImmersiveMapSettings) -> Bool {
        settings.scene.atmosphere.isEnabled && settings.scene.space.isTransparent == false
    }

    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.atmosphereEnabled = Self.isAtmosphereEnabled(settings: settings)
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .atmosphere,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        let uniform = AtmosphereUniform.make(settings: frameContext.services.settings.scene.atmosphere,
                                             earthScene: frameContext.earthSceneUniform,
                                             globe: frameContext.globeRenderUniform,
                                             projectionView: frameContext.cameraMatrices.projectionView,
                                             cameraEye: frameContext.cameraEye)
        // At the far plane, depth-tested: the halo draws after the globe
        // surface, so the sphere's pixels reject it and only the space
        // around the silhouette is shaded.
        encoder.setDepthStencilState(skyBackdropDepthState)
        atmosphereRenderer.draw(renderEncoder: encoder, uniform: uniform)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
