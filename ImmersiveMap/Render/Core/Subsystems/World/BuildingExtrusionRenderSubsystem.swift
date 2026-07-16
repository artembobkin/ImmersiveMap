// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Рисует выдавленные здания flat-режима. Solid: непрозрачная геометрия прямо
/// в world-пасс. Translucent: та же непрозрачная геометрия уходит в offscreen
/// building image (слой `.buildingImage`), а в world-пассе изображение
/// накладывается на карту одним фуллскрин-блендом с `buildingExtrusionAlpha` -
/// каждый пиксель тонируется ровно один раз, без швов между поверхностями.
final class BuildingExtrusionRenderSubsystem: RenderSubsystem {
    let name: String = "BuildingExtrusion"

    private let buildingImageTextureProvider: () -> MTLTexture?
    private let extrudedTilePipeline: ExtrudedTilePipeline
    private let extrudedDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState

    init(buildingImageTextureProvider: @escaping () -> MTLTexture?,
         extrudedTilePipeline: ExtrudedTilePipeline,
         extrudedDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState) {
        self.buildingImageTextureProvider = buildingImageTextureProvider
        self.extrudedTilePipeline = extrudedTilePipeline
        self.extrudedDepthState = extrudedDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .flat else {
            return
        }

        // Режим и альфа читаются из настроек кадра: их смена применяется
        // на лету, без пересоздания renderer'а (см. planner).
        let style = frameContext.services.settings.style
        switch layer {
        case .buildingImage:
            guard style.buildingExtrusionMode == .translucent else { return }
            drawBuildings(encoder: encoder, frameContext: frameContext)
        case .buildingExtrusion:
            switch style.buildingExtrusionMode {
            case .solid:
                drawBuildings(encoder: encoder, frameContext: frameContext)
            case .translucent:
                guard let buildingImageTexture = buildingImageTextureProvider() else { return }
                BuildingExtrusionDrawer.drawComposite(renderEncoder: encoder,
                                                      buildingImageTexture: buildingImageTexture,
                                                      alpha: style.buildingExtrusionAlpha,
                                                      extrudedTilePipeline: extrudedTilePipeline,
                                                      depthDisabledState: depthDisabledState)
            }
        default:
            return
        }
    }

    func handleMemoryWarning() {}

    func evict() {}

    private func drawBuildings(encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: frameContext.cameraUniform,
                                              placeTilesContext: frameContext.sharedState.tilePlacementState.placeTilesContext,
                                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                              extrudedTilePipeline: extrudedTilePipeline,
                                              extrudedDepthState: extrudedDepthState,
                                              depthDisabledState: depthDisabledState)
    }
}
