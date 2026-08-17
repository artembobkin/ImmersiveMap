// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The atmosphere halo around the globe. Sits between the starfield and the
/// globe surface in the world pass: it paints over space, and the sphere
/// then paints over the part of it that lies inside the silhouette.
final class AtmosphereRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "Atmosphere"

    private let atmosphereRenderer: AtmosphereRenderer
    private let depthDisabledState: MTLDepthStencilState

    init(atmosphereRenderer: AtmosphereRenderer,
         depthDisabledState: MTLDepthStencilState) {
        self.atmosphereRenderer = atmosphereRenderer
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
        // No depth: the halo is a backdrop, and whatever the sphere and the
        // content on it write afterwards simply paints over it.
        encoder.setDepthStencilState(depthDisabledState)
        atmosphereRenderer.draw(renderEncoder: encoder, uniform: uniform)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
