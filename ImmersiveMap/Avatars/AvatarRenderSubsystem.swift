// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  AvatarRenderSubsystem.swift
//  ImmersiveMap
//

import Metal

final class AvatarRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "Avatars"

    private let avatarsRenderer: AvatarsRenderer
    private let avatarSource: AvatarRenderSource
    private let depthDisabledState: MTLDepthStencilState

    var hasRenderableAvatars: Bool {
        avatarsRenderer.hasRenderableAvatars
    }

    init(avatarsRenderer: AvatarsRenderer,
         avatarSource: AvatarRenderSource,
         depthDisabledState: MTLDepthStencilState) {
        self.avatarsRenderer = avatarsRenderer
        self.avatarSource = avatarSource
        self.depthDisabledState = depthDisabledState
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.avatarsEnabled = builder.avatarsEnabled || hasRenderableAvatars
    }

    func update(frameContext: FrameContext) {
        avatarsRenderer.update(controller: avatarSource.currentAvatarController,
                               time: frameContext.time)
        frameContext.sharedState.avatarState.hasActiveAnimations = avatarsRenderer.hasActiveAnimations
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard let commandBuffer = frameContext.commandBuffer else {
            frameContext.services.diagnostics.recordSkipReason(.missingCommandBuffer)
            return
        }

        avatarsRenderer.compute(drawSize: frameContext.drawSize,
                                cameraUniform: frameContext.cameraUniform,
                                resolvedPresentation: frameContext.resolvedPresentation,
                                time: frameContext.time,
                                commandBuffer: commandBuffer,
                                frameSlotIndex: frameContext.frameSlotIndex)
        frameContext.sharedState.avatarState.hasActiveAnimations = avatarsRenderer.hasActiveAnimations
        frameContext.sharedState.avatarState.selectionSnapshot = avatarsRenderer.selectionSnapshot
            .withFrameIndex(frameContext.frameIndex)
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .avatars else { return }
        encoder.setDepthStencilState(depthDisabledState)
        RendererAvatarDrawer.drawAvatars(renderEncoder: encoder,
                                         screenMatrix: frameContext.cameraMatrices.screen,
                                         time: Float(frameContext.time),
                                         frameSlotIndex: frameContext.frameSlotIndex,
                                         avatarsRenderer: avatarsRenderer)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
