// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class StarfieldRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "Starfield"

    private let starfieldRenderer: StarfieldRenderer
    private let skyBackdropDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    init(starfieldRenderer: StarfieldRenderer,
         skyBackdropDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.starfieldRenderer = starfieldRenderer
        self.skyBackdropDepthState = skyBackdropDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext _: FrameContext) {}

    /// Whether anything outside the globe gets painted at all.
    ///
    /// This layer is the only one that paints there, and it paints all of it:
    /// the opaque fullscreen background, the stars, and the earth scene's Sun,
    /// whose disk, glow and limb halo all come out of `StarfieldRenderer`
    /// (`EarthSceneSettings.sun` only shapes them). Turning the layer off is
    /// therefore also what turns the Sun off, which is why transparent space
    /// needs no separate rule for it, and why the earth scene stays free to
    /// light the globe surface itself.
    static func isStarfieldEnabled(settings: ImmersiveMapSettings) -> Bool {
        settings.scene.space.isTransparent == false
    }

    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.starfieldEnabled = Self.isStarfieldEnabled(settings: settings)
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        // The nebula bake, once per renderer: encoded ahead of the world
        // pass on the frame's own command buffer, so the background's
        // sample always finds the texture written.
        guard frameContext.renderSurfaceMode == .spherical,
              Self.isStarfieldEnabled(settings: frameContext.services.settings),
              let commandBuffer = frameContext.commandBuffer else {
            return
        }
        starfieldRenderer.bakeNebulaIfNeeded(commandBuffer: commandBuffer)
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .starfield,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }

        // The sky draws after the globe surface, at the far plane: the
        // depth test rejects every fragment the sphere covered, so only
        // space is shaded.
        encoder.setDepthStencilState(skyBackdropDepthState)
        starfieldRenderer.draw(renderEncoder: encoder,
                               globe: frameContext.globeRenderUniform,
                               cameraView: frameContext.cameraMatrices.view,
                               cameraEye: frameContext.cameraEye,
                               drawSize: frameContext.drawSize,
                               nowTime: Float(frameContext.time))
        // Back to the encoder's neutral state, so no later layer inherits
        // the sky's depth test by accident.
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
