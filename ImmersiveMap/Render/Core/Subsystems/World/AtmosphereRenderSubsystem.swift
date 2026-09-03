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
    /// Scene depth (lessEqual, written, no stencil): the backdrop body joins
    /// the opaque set at the very back of the band, so hidden surface
    /// removal erases it under every painted slot.
    private let backdropDepthState: MTLDepthStencilState
    /// Far-plane lessEqual, no write: the flat sky paints only where the
    /// ground and the buildings left the cleared depth.
    private let skyBackdropDepthState: MTLDepthStencilState

    init(atmosphereRenderer: AtmosphereRenderer,
         depthDisabledState: MTLDepthStencilState,
         backdropDepthState: MTLDepthStencilState,
         skyBackdropDepthState: MTLDepthStencilState) {
        self.atmosphereRenderer = atmosphereRenderer
        self.depthDisabledState = depthDisabledState
        self.backdropDepthState = backdropDepthState
        self.skyBackdropDepthState = skyBackdropDepthState
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        if layer == .globeBackdrop {
            encodeBackdrop(encoder: encoder, frameContext: frameContext)
            return
        }
        guard layer == .atmosphere else { return }
        let settings = frameContext.services.settings
        let transition = frameContext.transition
        if frameContext.renderSurfaceMode == .spherical,
           transition <= 0,
           // The resting halo hugs the limb: with the planet filling the
           // whole viewport there is neither halo nor rim on screen.
           StarfieldRenderSubsystem.frameShowsSky(frameContext: frameContext) == false {
            return
        }
        let fog = HorizonFogUniform.make(transition: transition,
                                         geometryTransition: frameContext.globeRenderUniform.transition,
                                         cameraEye: frameContext.cameraEye,
                                         mapClearColor: settings.scene.mapClearColor,
                                         globeRadius: frameContext.globeRenderUniform.radius,
                                         hazeEnabled: settings.scene.space.isTransparent == false)
        let uniform = AtmosphereUniform.make(globe: frameContext.globeRenderUniform,
                                             projectionView: frameContext.cameraMatrices.projectionView,
                                             cameraEye: frameContext.cameraEye,
                                             fog: fog)
        // On the resting sphere depth is off: the rim glow paints over the
        // ground, whose opaque layers wrote their rank depth at the far
        // plane. From the first step of the unroll the halo is the sky side
        // of the edge haze (the ground haze takes the rim's place), painted
        // only where the surface left the far plane.
        encoder.setDepthStencilState(transition <= 0 ? depthDisabledState : skyBackdropDepthState)
        atmosphereRenderer.draw(renderEncoder: encoder, uniform: uniform)
        encoder.setDepthStencilState(depthDisabledState)
    }

    /// The luminous planet body, before the tiles. No sky gate: with the
    /// planet filling the viewport the body must still fill unloaded slots,
    /// and everywhere the map has painted it costs nothing (hidden surface
    /// removal). During the unfurl it fades out over the halo's window and
    /// then stops drawing: past that the surface leaves the sphere the body
    /// is fitted to.
    private func encodeBackdrop(encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .spherical else { return }
        let uniform = GlobeBackdropUniform.make(globe: frameContext.globeRenderUniform,
                                                cameraMatrix: frameContext.cameraMatrices.projectionView,
                                                cameraEye: frameContext.cameraEye)
        guard uniform.fade > 0 else { return }
        encoder.setDepthStencilState(uniform.fade >= 1.0 ? backdropDepthState : depthDisabledState)
        atmosphereRenderer.drawBackdrop(renderEncoder: encoder, uniform: uniform)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
