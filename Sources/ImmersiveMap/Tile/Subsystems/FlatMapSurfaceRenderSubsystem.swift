// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The flat ground: the main coverage's sources through the vector drawer
/// (`FlatMapSurfaceDrawer`), every tile as geometry, but where a ring rule
/// draws the ground from a texture (`RasterTileRenderSubsystem`, which
/// draws first in the ground's layer). Two layers: the ground's fills
/// (`RenderLayer.flatMapSurface`), and what lies on the ground, the line
/// ribbons, the roads and the bridges (`RenderLayer.flatMapRoads`), after
/// the buildings and the models, which they never paint over.
/// Nothing is drawn under them: beyond the last rule the haze paints the
/// horizon. With the relief on, a flattened tile rises by its terrain
/// (`GroundReliefStore`).
final class FlatMapSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "FlatMapSurface"

    private let tilePipeline: TilePipeline
    private let groundOwnerState: MTLDepthStencilState
    private let tileStencilTestState: MTLDepthStencilState
    private let roadRankState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture
    private let groundReliefStore: GroundReliefStore?
    /// The tile zoom the ground is flattened from, the coarsest the
    /// terrain under the screen's centre is read at.
    private let groundFlatteningFromTileZoom: Int?
    /// The depth of the terrain under the screen's centre last known, kept
    /// while the terrain there is on its way, so the road widths do not
    /// jump.
    private var groundReliefCentreDepth: Float?

    init(tilePipeline: TilePipeline,
         groundOwnerState: MTLDepthStencilState,
         tileStencilTestState: MTLDepthStencilState,
         roadRankState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture,
         groundReliefStore: GroundReliefStore? = nil,
         groundFlatteningFromTileZoom: Int? = nil) {
        self.tilePipeline = tilePipeline
        self.groundOwnerState = groundOwnerState
        self.tileStencilTestState = tileStencilTestState
        self.roadRankState = roadRankState
        self.depthDisabledState = depthDisabledState
        self.debugOverlayControls = debugOverlayControls
        self.groundShadowMaskTextureProvider = groundShadowMaskTextureProvider
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
        self.groundReliefStore = groundReliefStore
        self.groundFlatteningFromTileZoom = groundFlatteningFromTileZoom
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        let part: FlatMapSurfaceDrawer.Part
        switch layer {
        case .flatMapSurface: part = .ground
        case .flatMapRoads: part = .roads
        default: return
        }
        guard frameContext.renderSurfaceMode == .flat else {
            return
        }
        let placeTilesContext = frameContext.sharedState.tilePlacementState.placeTilesContext
        guard placeTilesContext.tilePlacements.isEmpty == false else { return }

        let isWireframeEnabled = debugOverlayControls.snapshot().wireframeEnabled
        let groundShadowMask = GroundShadowMaskBinding.resolve(frameContext: frameContext,
                                                               maskTexture: groundShadowMaskTextureProvider(),
                                                               fallbackTexture: groundShadowMaskFallbackTexture)
        let drawableSizePx = SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height))
        // The drawer sets its own depth-stencil states per group: the
        // opaque ground writes the rank depth and owns the tile-priority
        // stencil, the road buckets write their ranks, the rest only test.
        // A source draws at full extent, and the stencil settles which
        // source a pixel shows (`TileSourceStencilPriority`): the ring
        // prepass marked the rings, and a source's reference is its ring
        // above its zoom (`FlatTileStencilPacking`).
        GroundFogUniform.bind(GroundFogUniform.resolve(frameContext: frameContext), encoder: encoder)
        let stencilPacking = FlatTileStencilPacking(bands: frameContext.visibleContent.flatRingBands,
                                                    targetZoom: frameContext.visibleContent.tileZoomLevel)
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  cpuCameraMatrix: frameContext.cameraMatrices.projectionView,
                                  cameraZoom: frameContext.animatedZoom,
                                  pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                  drawableSizePx: drawableSizePx,
                                  placeTilesContext: placeTilesContext,
                                  flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                  groundShadowMask: groundShadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  roadRankState: roadRankState,
                                  stencilPacking: stencilPacking,
                                  part: part,
                                  isWireframeEnabled: isWireframeEnabled,
                                  groundRelief: groundReliefStore,
                                  pointWidthReferenceDepth: reliefCentreDepth(frameContext: frameContext))
        encoder.setDepthStencilState(depthDisabledState)
    }

    /// The depth the road widths are stated at on a relief: the terrain
    /// under the screen's centre, one lookup a frame. Nil off the relief.
    private func reliefCentreDepth(frameContext: FrameContext) -> Float? {
        guard let groundReliefStore else { return nil }
        if let depth = GroundReliefCameraLift.centreGroundDepth(store: groundReliefStore,
                                                                cameraMatrix: frameContext.cameraMatrices.projectionView,
                                                                centerWorldMercator: frameContext.visibleContent.centerWorldMercator,
                                                                tileZoom: frameContext.visibleContent.tileZoomLevel,
                                                                renderMapSize: frameContext.resolvedPresentation.flatRenderState.renderMapSize) {
            groundReliefCentreDepth = depth
        }
        return groundReliefCentreDepth
    }

    func handleMemoryWarning() {
        groundReliefStore?.removeAll()
    }

    func evict() {
        groundReliefStore?.removeAll()
    }
}
