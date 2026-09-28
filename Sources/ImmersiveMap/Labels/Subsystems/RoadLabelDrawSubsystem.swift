// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RoadLabelDrawSubsystem.swift
//  ImmersiveMap
//

import Metal
import simd

/// Mirrors `RoadLabelSceneDepthUniforms` in LabelTextCommon.h: the eye takes
/// 16 bytes on both sides, so the viewport follows at 144.
struct RoadLabelSceneDepthUniforms {
    var projectionView: simd_float4x4
    var inverseProjectionView: simd_float4x4
    var eye: SIMD3<Float>
    var viewportSize: SIMD2<Float>
    var enabled: UInt32
}

/// Draws the road names in the overlay pass. From
/// `RoadSettings.hidesBehindBuildingsFromZoom` on the flat map, the buildings
/// and the models paint over them: the world pass keeps its depth for the
/// frame (`FrameContextSharedState.sceneDepthForLabelsRequested`), and the
/// glyph fragments behind a building are dropped, pixel by pixel. Nothing
/// else about the names changes: they keep their place in the collisions
/// and their fades.
final class RoadLabelDrawSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "RoadLabelDraw"

    private let textRenderer: TextRenderer
    private let labelDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    /// Bound where the frame keeps no world depth: a depth texture of 1.0,
    /// which nothing is behind.
    private let fallbackDepthTexture: MTLTexture
    private let hidesBehindBuildingsFromZoom: Float

    private(set) var hasRenderableLabels: Bool = false

    init(textRenderer: TextRenderer,
         labelDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         fallbackDepthTexture: MTLTexture,
         hidesBehindBuildingsFromZoom: Float,
         metalDevice _: MTLDevice) {
        self.textRenderer = textRenderer
        self.labelDepthState = labelDepthState
        self.depthDisabledState = depthDisabledState
        self.fallbackDepthTexture = fallbackDepthTexture
        self.hidesBehindBuildingsFromZoom = hidesBehindBuildingsFromZoom
    }

    func update(frameContext: FrameContext) {
        hasRenderableLabels = frameContext.sharedState.roadLabelState.drawLabels.isEmpty == false
        if hasRenderableLabels, Self.paintsOverNames(frameContext: frameContext,
                                                     fromZoom: hidesBehindBuildingsFromZoom) {
            frameContext.sharedState.sceneDepthForLabelsRequested = true
        }
    }

    /// Whether the buildings paint over the road names this frame: on the
    /// flat map, where the names and the buildings are, from the zoom.
    static func paintsOverNames(frameContext: FrameContext, fromZoom zoom: Float) -> Bool {
        frameContext.renderSurfaceMode == .flat
            && frameContext.screenSpaceProjectionMode == .flat
            && Float(frameContext.zoom) >= zoom
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

        // Same depth as BaseLabelDrawSubsystem: the overlay pass's own
        // depth orders halo under fill.
        encoder.setDepthStencilState(labelDepthState)
        let sceneDepth = frameContext.sharedState.sceneDepthTexture
        let projectionView = frameContext.cameraMatrices.projectionView
        let sceneDepthUniforms = RoadLabelSceneDepthUniforms(
            projectionView: projectionView,
            inverseProjectionView: projectionView.inverse,
            eye: frameContext.cameraEye,
            viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height)),
            enabled: sceneDepth == nil ? 0 : 1)
        RendererLabelDrawer.drawRoadLabels(renderEncoder: encoder,
                                           screenMatrix: frameContext.cameraMatrices.screen,
                                           screenScale: frameContext.screenScale,
                                           textRenderer: textRenderer,
                                           roadDrawLabels: roadLabelState.drawLabels,
                                           sceneDepth: sceneDepth ?? fallbackDepthTexture,
                                           sceneDepthUniforms: sceneDepthUniforms)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
