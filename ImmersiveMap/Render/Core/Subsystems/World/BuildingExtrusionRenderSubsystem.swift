// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the extruded buildings of flat mode. Solid path: opaque geometry
/// straight into the world pass. Composited path (translucent and the
/// solidAtHighZoom zoom transition): the same opaque geometry goes into the
/// offscreen building image (the `.buildingImage` layer), and in the world pass
/// the image is composited over the map with a single fullscreen blend using the
/// frame alpha, so each pixel is tinted exactly once, with no seams between surfaces.
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

        // Mode and alpha are read from the frame settings: changing them applies
        // on the fly, without recreating the renderer (see planner). The per-frame
        // path is resolved the same way as in RenderPassGraph.plan.
        let style = frameContext.services.settings.style
        let path = BuildingExtrusionPathResolver.resolve(style: style, zoom: frameContext.zoom)
        switch layer {
        case .buildingImage:
            guard case .composited = path else { return }
            drawBuildings(encoder: encoder, frameContext: frameContext)
        case .buildingExtrusion:
            switch path {
            case .solid:
                drawBuildings(encoder: encoder, frameContext: frameContext)
            case .composited(let alpha):
                guard let buildingImageTexture = buildingImageTextureProvider() else { return }
                BuildingExtrusionDrawer.drawComposite(renderEncoder: encoder,
                                                      buildingImageTexture: buildingImageTexture,
                                                      alpha: alpha,
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
