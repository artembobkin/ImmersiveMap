// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  PinRenderSubsystem.swift
//  ImmersiveMap
//

import Metal

final class PinRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "Pins"

    private let pinsRenderer: PinsRenderer
    private let pinSource: PinRenderSource
    private let depthDisabledState: MTLDepthStencilState

    var hasRenderablePins: Bool {
        pinsRenderer.hasRenderablePins
    }

    init(pinsRenderer: PinsRenderer,
         pinSource: PinRenderSource,
         depthDisabledState: MTLDepthStencilState) {
        self.pinsRenderer = pinsRenderer
        self.pinSource = pinSource
        self.depthDisabledState = depthDisabledState
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.pinsEnabled = builder.pinsEnabled || hasRenderablePins
    }

    func update(frameContext: FrameContext) {
        pinsRenderer.update(controller: pinSource.currentPinController,
                               time: frameContext.time)
        frameContext.sharedState.pinState.hasActiveAnimations = pinsRenderer.hasActiveAnimations
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard let commandBuffer = frameContext.commandBuffer else {
            frameContext.services.diagnostics.recordSkipReason(.missingCommandBuffer)
            return
        }

        pinsRenderer.compute(drawSize: frameContext.drawSize,
                                cameraUniform: frameContext.cameraUniform,
                                resolvedPresentation: frameContext.resolvedPresentation,
                                time: frameContext.time,
                                commandBuffer: commandBuffer,
                                frameSlotIndex: frameContext.frameSlotIndex)
        frameContext.sharedState.pinState.hasActiveAnimations = pinsRenderer.hasActiveAnimations
        frameContext.sharedState.selectionPickData.append(
            pinsRenderer.selectionSnapshot.withFrameIndex(frameContext.frameIndex))
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .pins else { return }
        encoder.setDepthStencilState(depthDisabledState)
        RendererPinDrawer.drawPins(renderEncoder: encoder,
                                         screenMatrix: frameContext.cameraMatrices.screen,
                                         time: Float(frameContext.time),
                                         frameSlotIndex: frameContext.frameSlotIndex,
                                         pinsRenderer: pinsRenderer)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
