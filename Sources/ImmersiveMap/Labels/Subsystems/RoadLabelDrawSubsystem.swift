// Copyright (c) 2025-2026 Artem Bobkin.
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
/// frame (`SceneDepthFrameState.isRequestedForLabels`), and the
/// glyph fragments behind a building are dropped, pixel by pixel. Nothing
/// else about the names changes: they keep their place in the collisions
/// and their fades.
final class RoadLabelDrawSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "RoadLabelDraw"

    private let textAtlas: TextAtlas
    private let pipelines: LabelPipelines
    private let labelDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    /// Bound where the frame keeps no world depth: a depth texture of 1.0,
    /// which nothing is behind.
    private let fallbackDepthTexture: MTLTexture
    private let hidesBehindBuildingsFromZoom: Float

    private(set) var hasRenderableLabels: Bool = false

    init(textAtlas: TextAtlas,
         pipelines: LabelPipelines,
         labelDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         fallbackDepthTexture: MTLTexture,
         hidesBehindBuildingsFromZoom: Float,
         metalDevice _: MTLDevice) {
        self.textAtlas = textAtlas
        self.pipelines = pipelines
        self.labelDepthState = labelDepthState
        self.depthDisabledState = depthDisabledState
        self.fallbackDepthTexture = fallbackDepthTexture
        self.hidesBehindBuildingsFromZoom = hidesBehindBuildingsFromZoom
    }

    func update(frameContext: FrameContext) {
        hasRenderableLabels = frameContext.state[RoadLabelState.self].drawLabels.isEmpty == false
        if hasRenderableLabels, Self.paintsOverNames(frameContext: frameContext,
                                                     fromZoom: hidesBehindBuildingsFromZoom) {
            frameContext.state[SceneDepthFrameState.self].isRequestedForLabels = true
        }
    }

    /// Whether the buildings paint over the road names this frame: on the
    /// flat map, where the names and the buildings are, from the zoom.
    static func paintsOverNames(frameContext: FrameContext, fromZoom zoom: Float) -> Bool {
        frameContext.renderSurfaceMode == .flat
            && frameContext.screenSpaceProjectionMode == .flat
            && Float(frameContext.planningZoom) >= zoom
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.labelsEnabled = builder.labelsEnabled || hasRenderableLabels
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry) {
        if let runtimeMetaBuffer = frameContext.state[RoadLabelState.self].runtimeMetaBuffer {
            resourceRegistry.setBuffer(runtimeMetaBuffer, named: .roadLabelRuntimeBuffer)
        }
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .labels else {
            return
        }

        let roadLabelState = frameContext.state[RoadLabelState.self]
        guard roadLabelState.instanceCount > 0,
              roadLabelState.glyphCount > 0,
              roadLabelState.drawLabels.isEmpty == false else {
            return
        }

        // Same depth as BaseLabelDrawSubsystem: the overlay pass's own
        // depth orders halo under fill.
        encoder.setDepthStencilState(labelDepthState)
        let sceneDepth = frameContext.state[SceneDepthFrameState.self].texture
        // The eye ray through a pixel comes from the CPU's matrix, whose
        // inverse unprojects. The anchor's depth is compared with the
        // scene depth the GPU wrote, so it is projected with the uniform's
        // matrix, whose z is the GPU's (RenderCamera.gpuClipDepthAdjustment):
        // the roads lie under it there, the walls over it.
        let sceneDepthUniforms = RoadLabelSceneDepthUniforms(
            projectionView: frameContext.cameraUniform.matrix,
            inverseProjectionView: frameContext.cameraMatrices.projectionView.inverse,
            eye: frameContext.cameraEye,
            viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height)),
            enabled: sceneDepth == nil ? 0 : 1)
        RendererLabelDrawer.drawRoadLabels(renderEncoder: encoder,
                                           screenMatrix: frameContext.cameraMatrices.screen,
                                           screenScale: frameContext.screenScale,
                                           textAtlas: textAtlas,
                                           pipelines: pipelines,
                                           roadDrawLabels: roadLabelState.drawLabels,
                                           sceneDepth: sceneDepth ?? fallbackDepthTexture,
                                           sceneDepthUniforms: sceneDepthUniforms,
                                           labelOpacity: frameContext.services.labelOpacity)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
