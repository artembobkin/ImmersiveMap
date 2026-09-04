// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The air around the surface's edge, drawn last in the world pass on both
/// surfaces: the globe's atmosphere and limb feather, the flat map's fog
/// band, and their handover through the morph (`HorizonFrameResolver`).
///
/// One pipeline, up to two draws split by the depth buffer. The sky draw
/// runs under the far-plane lessEqual state and shades only pixels nothing
/// painted; the ground draw under the far-plane greater state and shades
/// only painted pixels, clamping its angle to the edge. Each pixel is shaded
/// once. Both are skipped when the edge is farther below the frame than the
/// haze reaches, which at street pitch is every frame; transparent space
/// skips the sky draw, since nothing may be painted around the globe.
final class HorizonRenderSubsystem: RenderSubsystem {
    let name: String = "Horizon"

    private let horizonRenderer: HorizonRenderer
    private let skyDepthState: MTLDepthStencilState
    private let groundDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let supportsFramebufferFetch: Bool

    init(horizonRenderer: HorizonRenderer,
         skyDepthState: MTLDepthStencilState,
         groundDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         supportsFramebufferFetch: Bool) {
        self.horizonRenderer = horizonRenderer
        self.skyDepthState = skyDepthState
        self.groundDepthState = groundDepthState
        self.depthDisabledState = depthDisabledState
        self.supportsFramebufferFetch = supportsFramebufferFetch
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    /// The frame's haze, resolved from the settings, the transition and the
    /// camera; internal so tests can ask what a frame would draw.
    static func resolveHaze(frameContext: FrameContext) -> HorizonHaze {
        HorizonFrameResolver.resolve(settings: frameContext.services.settings,
                                     transition: frameContext.transition,
                                     globe: frameContext.globeRenderUniform,
                                     renderSurfaceMode: frameContext.renderSurfaceMode,
                                     cameraEye: frameContext.cameraEye,
                                     projectionView: frameContext.cameraMatrices.projectionView,
                                     verticalFovRadians: RenderCamera.verticalFovRadians,
                                     drawableHeightPx: Float(frameContext.drawSize.height))
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .horizon else { return }
        let haze = Self.resolveHaze(frameContext: frameContext)
        guard haze.drawsSky || haze.drawsGround else { return }
        let uniform = HorizonUniform.make(haze: haze,
                                          projectionView: frameContext.cameraMatrices.projectionView,
                                          cameraEye: frameContext.cameraEye)
        // The framebuffer-fetch world pass carries a second building
        // attachment; every pipeline in it must declare that attachment to
        // stay pass-compatible (same decision as RenderPassGraph.plan).
        let withBuildingImageAttachment = BuildingExtrusionPathResolver.usesInPassBuildingImage(
            style: frameContext.services.settings.style,
            zoom: frameContext.zoom,
            renderSurfaceMode: frameContext.renderSurfaceMode,
            supportsFramebufferFetch: supportsFramebufferFetch
        )
        if haze.drawsGround {
            encoder.setDepthStencilState(groundDepthState)
            horizonRenderer.draw(renderEncoder: encoder,
                                 uniform: uniform,
                                 groundSide: true,
                                 withBuildingImageAttachment: withBuildingImageAttachment)
        }
        if haze.drawsSky {
            encoder.setDepthStencilState(skyDepthState)
            horizonRenderer.draw(renderEncoder: encoder,
                                 uniform: uniform,
                                 groundSide: false,
                                 withBuildingImageAttachment: withBuildingImageAttachment)
        }
        // Back to the encoder's neutral state, so no later layer inherits
        // the horizon's depth tests by accident.
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
