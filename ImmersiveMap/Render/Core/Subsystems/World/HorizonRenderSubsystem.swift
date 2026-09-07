// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The air around the surface's edge, drawn last in the world pass on both
/// surfaces: the globe's atmosphere and limb feather, the flat map's sky
/// and haze, with the morph between them bare (`HorizonFrameResolver`).
///
/// One geometry (the band), up to two draws split by the depth buffer. The sky draw
/// runs under the far-plane lessEqual state and shades only pixels nothing
/// painted; the ground draw under the far-plane greater state and shades
/// only painted pixels that no building or model stands on (the surface
/// mask bit, `TileSourceStencilPriority.surfaceMaskBit`), clamping its angle
/// to the edge. Each pixel is shaded once. Both are skipped when the edge is farther below the frame than the
/// haze reaches, which at street pitch is every frame; transparent space
/// skips the globe's sky draw, since nothing may be painted around the
/// planet, while the plane's sky still paints over its own clear colour.
final class HorizonRenderSubsystem: RenderSubsystem {
    let name: String = "Horizon"

    private let horizonRenderer: HorizonRenderer
    private let skyDepthState: MTLDepthStencilState
    private let groundDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    init(horizonRenderer: HorizonRenderer,
         skyDepthState: MTLDepthStencilState,
         groundDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.horizonRenderer = horizonRenderer
        self.skyDepthState = skyDepthState
        self.groundDepthState = groundDepthState
        self.depthDisabledState = depthDisabledState
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
        if haze.drawsGround {
            encoder.setDepthStencilState(groundDepthState)
            // The ground state tests the surface mask bit against zero: the
            // haze lands on the ground, never on a building or a model.
            encoder.setStencilReferenceValue(0)
            horizonRenderer.draw(renderEncoder: encoder,
                                 uniform: uniform,
                                 groundSide: true)
        }
        if haze.drawsSky {
            encoder.setDepthStencilState(skyDepthState)
            horizonRenderer.draw(renderEncoder: encoder,
                                 uniform: uniform,
                                 groundSide: false)
        }
        // Back to the encoder's neutral state, so no later layer inherits
        // the horizon's depth tests by accident.
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
