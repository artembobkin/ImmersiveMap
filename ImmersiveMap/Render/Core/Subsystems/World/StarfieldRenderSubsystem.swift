// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

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

    /// Whether the space décor is painted at all. Space itself is the world
    /// pass's clear color; this layer draws only the stars over it, and the
    /// starfield is the only space décor.
    static func isStarfieldEnabled(settings: ImmersiveMapSettings) -> Bool {
        settings.scene.space.isTransparent == false
    }

    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.starfieldEnabled = Self.isStarfieldEnabled(settings: settings)
    }

    /// At region zooms the planet fills the whole viewport: no sky pixel
    /// exists, and the stars (drawn first, painted over by the opaque
    /// ground) would be pure waste. Valid on the resting sphere only;
    /// mid-morph the décor draws and fades with the transition as before.
    static func frameShowsSky(frameContext: FrameContext) -> Bool {
        let globe = frameContext.globeRenderUniform
        guard globe.transition <= 0 else { return true }
        return GlobeSkyVisibilityMath.isSkyVisible(
            inverseProjectionView: simd_inverse(frameContext.cameraMatrices.projectionView),
            eye: frameContext.cameraEye,
            radius: globe.radius
        )
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .starfield,
              frameContext.renderSurfaceMode == .spherical,
              Self.frameShowsSky(frameContext: frameContext) else {
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
