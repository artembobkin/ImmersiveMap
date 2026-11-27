// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  BaseLabelDrawSubsystem.swift
//  ImmersiveMap
//

import Metal

final class BaseLabelDrawSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "BaseLabelDraw"

    private let textAtlas: TextAtlas
    private let pipelines: LabelPipelines
    private let poiSpriteAtlas: PoiSpriteAtlas
    private let labelDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    private(set) var hasRenderableLabels: Bool = false

    init(textAtlas: TextAtlas,
         pipelines: LabelPipelines,
         poiSpriteAtlas: PoiSpriteAtlas,
         labelDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         metalDevice _: MTLDevice) {
        self.textAtlas = textAtlas
        self.pipelines = pipelines
        self.poiSpriteAtlas = poiSpriteAtlas
        self.labelDepthState = labelDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext: FrameContext) {
        hasRenderableLabels = frameContext.state[BaseLabelState.self].labelInputsCount > 0
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.labelsEnabled = builder.labelsEnabled || hasRenderableLabels
    }

    func prepareGPU(frameContext: FrameContext) {
        if let labelRuntimeMetaBuffer = frameContext.state[BaseLabelState.self].labelRuntimeMetaBuffer {
            RenderResourceName.baseLabelRuntimeBuffer.name(labelRuntimeMetaBuffer)
        }
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .labels else {
            return
        }

        let baseLabelState = frameContext.state[BaseLabelState.self]
        guard baseLabelState.labelInputsCount > 0 else {
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
        // (TextShader.metal). Nothing else writes that depth, so the scene
        // models, drawn in the world pass, never hide a label.
        encoder.setDepthStencilState(labelDepthState)
        RendererLabelDrawer.drawBaseLabels(renderEncoder: encoder,
                                           screenMatrix: frameContext.cameraMatrices.screen,
                                           screenScale: frameContext.screenScale,
                                           textAtlas: textAtlas,
                                           pipelines: pipelines,
                                           poiSpriteAtlas: poiSpriteAtlas,
                                           screenPositionsBuffer: screenPositionsBuffer,
                                           labelRuntimeMetaBuffer: labelRuntimeMetaBuffer,
                                           baseLabelsDrawBatches: baseLabelState.baseLabelsDrawBatches,
                                           handover: frameContext.groundHandover,
                                           labelOpacity: frameContext.services.labelOpacity)
        encoder.setDepthStencilState(depthDisabledState)
    }

}
