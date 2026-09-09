// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelDrawSubsystem.swift
//  ImmersiveMap
//

import Metal

final class BaseLabelDrawSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "BaseLabelDraw"

    private let textRenderer: TextRenderer
    private let poiSpriteAtlas: PoiSpriteAtlas
    private let labelDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    private(set) var hasRenderableLabels: Bool = false

    init(textRenderer: TextRenderer,
         poiSpriteAtlas: PoiSpriteAtlas,
         labelDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         metalDevice _: MTLDevice) {
        self.textRenderer = textRenderer
        self.poiSpriteAtlas = poiSpriteAtlas
        self.labelDepthState = labelDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext: FrameContext) {
        hasRenderableLabels = frameContext.sharedState.baseLabelState.labelInputsCount > 0
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.labelsEnabled = builder.labelsEnabled || hasRenderableLabels
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry) {
        if let labelRuntimeMetaBuffer = frameContext.sharedState.baseLabelState.labelRuntimeMetaBuffer {
            resourceRegistry.setBuffer(labelRuntimeMetaBuffer, named: .baseLabelRuntimeBuffer)
        }
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .labels else {
            return
        }

        let baseLabelState = frameContext.sharedState.baseLabelState
        let labelCount = baseLabelState.labelInputsCount
        let activeLabelSpanCount = baseLabelState.activeLabelSpanCount
        guard labelCount > 0, activeLabelSpanCount > 0 else {
            return
        }

        guard let labelRuntimeMetaBuffer = baseLabelState.labelRuntimeMetaBuffer else {
            return
        }

        guard let screenPositionsBuffer = baseLabelState.screenPositionsBuffer else {
            return
        }

        // The labels always draw in the overlay pass over its own cleared
        // depth: they rasterize at the far plane (see LabelTextVertex.metal)
        // and write fill and halo depths just short of it, so the halo of a
        // later glyph never covers the fill of an earlier one
        // (TextShader.metal), while the scene model occlusion prepass,
        // nearer still, clips them to the model silhouettes.
        encoder.setDepthStencilState(labelDepthState)
        RendererLabelDrawer.drawBaseLabels(renderEncoder: encoder,
                                           screenMatrix: frameContext.cameraMatrices.screen,
                                           screenScale: frameContext.screenScale,
                                           textRenderer: textRenderer,
                                           poiSpriteAtlas: poiSpriteAtlas,
                                           screenPositionsBuffer: screenPositionsBuffer,
                                           labelRuntimeMetaBuffer: labelRuntimeMetaBuffer,
                                           baseLabelsDrawBatches: baseLabelState.baseLabelsDrawBatches)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
