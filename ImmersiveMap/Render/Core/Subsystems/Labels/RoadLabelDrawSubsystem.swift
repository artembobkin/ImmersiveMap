// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RoadLabelDrawSubsystem.swift
//  ImmersiveMap
//

import Metal

final class RoadLabelDrawSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "RoadLabelDraw"

    private let textRenderer: TextRenderer

    private(set) var hasRenderableLabels: Bool = false

    init(textRenderer: TextRenderer,
         metalDevice _: MTLDevice) {
        self.textRenderer = textRenderer
    }

    func update(frameContext: FrameContext) {
        hasRenderableLabels = frameContext.sharedState.roadLabelState.drawLabels.isEmpty == false
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.labelsEnabled = builder.labelsEnabled || hasRenderableLabels
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry) {
        if let runtimeMetaBuffer = frameContext.sharedState.roadLabelState.runtimeMetaBuffer {
            resourceRegistry.setBuffer(runtimeMetaBuffer, named: .roadLabelRuntimeBuffer)
        }
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .labels else {
            return
        }

        let roadLabelState = frameContext.sharedState.roadLabelState
        guard roadLabelState.instanceCount > 0,
              roadLabelState.glyphCount > 0,
              roadLabelState.drawLabels.isEmpty == false else {
            return
        }

        RendererLabelDrawer.drawRoadLabels(renderEncoder: encoder,
                                           screenMatrix: frameContext.cameraMatrices.screen,
                                           textRenderer: textRenderer,
                                           roadDrawLabels: roadLabelState.drawLabels)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
