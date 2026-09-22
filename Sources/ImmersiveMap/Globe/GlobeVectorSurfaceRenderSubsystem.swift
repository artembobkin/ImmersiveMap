// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The globe's ground: the placements' ground geometry projected onto the
/// sphere in the vertex stage (`GlobeVectorSurfaceDrawer`). A tile's extent
/// is its full square: which source owns a pixel is the tile-priority
/// stencil's answer, marked by whatever draws a tile's opaque ground first,
/// and the far hemisphere goes to back-face culling. Every source draws in
/// one call, finest first, so a coarser source's overflow stays out of a
/// finer tile's ground.
final class GlobeVectorSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeVectorSurface"

    private let pipeline: TilePipeline
    private let depthDisabledState: MTLDepthStencilState
    private let opaqueDepthState: MTLDepthStencilState
    private let translucentDepthState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState

    init(pipeline: TilePipeline,
         depthDisabledState: MTLDepthStencilState,
         opaqueDepthState: MTLDepthStencilState,
         translucentDepthState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState) {
        self.pipeline = pipeline
        self.depthDisabledState = depthDisabledState
        self.opaqueDepthState = opaqueDepthState
        self.translucentDepthState = translucentDepthState
        self.debugOverlayControls = debugOverlayControls
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .globeVectorSurface,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }
        let placeTilesContext = frameContext.sharedState.tilePlacementState.placeTilesContext
        guard placeTilesContext.tilePlacements.isEmpty == false else { return }

        let globe = frameContext.globeRenderUniform
        let pureSphere = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                            transition: globe.transition)
        let globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: frameContext.cameraUniform.matrix)
        let isWireframeEnabled = debugOverlayControls.snapshot().wireframeEnabled
        encoder.setDepthStencilState(depthDisabledState)
        GlobeVectorSurfaceDrawer.draw(renderEncoder: encoder,
                                      cameraUniform: frameContext.cameraUniform,
                                      globe: globe,
                                      cameraZoom: frameContext.zoom,
                                      pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                      drawableHeightPx: Float(frameContext.drawSize.height),
                                      renderMapSize: frameContext.resolvedPresentation.renderNormalizationState.flatRenderMapSize,
                                      placeTilesContext: placeTilesContext,
                                      pipeline: pipeline,
                                      opaqueDepthState: opaqueDepthState,
                                      translucentDepthState: translucentDepthState,
                                      depthDisabledState: depthDisabledState,
                                      isWireframeEnabled: isWireframeEnabled,
                                      pureSphere: pureSphere,
                                      globeFrame: globeFrame,
                                      linelessTiles: frameContext.visibleContent.linelessTiles)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
