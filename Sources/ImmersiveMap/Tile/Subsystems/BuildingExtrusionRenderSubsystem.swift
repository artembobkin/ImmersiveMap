// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the extruded buildings of flat mode: opaque geometry straight into
/// the world pass, before the ground, which then fails its depth test under
/// them. Always solid; there is no translucent path. A building a drawn
/// model stands in for (`SceneModelFrameState.replacedBuildings`) is left
/// out of both the world pass and the shadow casters, and its tile still
/// draws in one call, from a working index buffer without it
/// (`HiddenBuildingIndexBuffers`).
///
/// The buildings draw from a camera zoom on
/// (`ExtrusionSettings.buildingsMinimumZoom`), from the tiles of the
/// frame's target zoom only (`BuildingCoveragePlanner`): a coarser tile
/// standing in where those have not arrived draws none. A tile's buildings
/// also wait for the model tile
/// over them (`FrameContextSharedState.pendingModelTiles`), so the ones a
/// model stands in for are left out from their first frame. Each tile's
/// buildings grow out of the flat map from the frame they first draw in
/// (`ExtrusionRise`), their shadows with them: all of them when the camera
/// reaches the zoom, and a tile arriving later on its own. Leaving the
/// zoom, they are gone at once. The coverage is planned from the grid's zoom on
/// regardless (`BuildingCoveragePlanner`), so the tiles are there to rise.
final class BuildingExtrusionRenderSubsystem: RenderSubsystem {
    let name: String = "BuildingExtrusion"

    private let extrudedTilePipeline: ExtrudedTilePipeline
    /// Depth-only state of the shadow-caster pass (no stencil attachment there).
    private let extrudedDepthState: MTLDepthStencilState
    /// World-pass buildings: scene depth plus the tile-priority stencil test.
    private let extrudedStencilTestState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private let debugOverlayControls: DebugOverlayControlState
    /// The index buffers the tiles draw from while the frame's models
    /// stand in for some of their buildings, shared by the world pass and
    /// the casters.
    private let hiddenBuildingIndexBuffers = HiddenBuildingIndexBuffers()
    private let extrusion: ImmersiveMapSettings.ExtrusionSettings
    private var rise = ExtrusionRise<VisibleTile>()
    /// How far each of the frame's building placements has risen,
    /// index-aligned with them, 0 for one not drawn.
    private var heightScales: [Float] = []
    private var drawsAny = false

    init(extrudedTilePipeline: ExtrudedTilePipeline,
         extrudedDepthState: MTLDepthStencilState,
         extrudedStencilTestState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture,
         extrusion: ImmersiveMapSettings.ExtrusionSettings = ImmersiveMapSettings.ExtrusionSettings(),
         debugOverlayControls: DebugOverlayControlState) {
        self.debugOverlayControls = debugOverlayControls
        self.extrusion = extrusion
        self.extrudedTilePipeline = extrudedTilePipeline
        self.extrudedDepthState = extrudedDepthState
        self.extrudedStencilTestState = extrudedStencilTestState
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
    }

    func update(frameContext: FrameContext) {
        let isRaised = frameContext.renderSurfaceMode == .flat
            && frameContext.zoom >= extrusion.buildingsMinimumZoom
        let placements = frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext.tilePlacements
        let pendingModelTiles = frameContext.sharedState.pendingModelTiles
        // The placements that draw: the camera at the buildings' zoom, and
        // the model tile over the placement, if any, in hand.
        let drawnKeys: [VisibleTile?] = placements.map { placement in
            guard isRaised,
                  pendingModelTiles.contains(Self.modelTile(over: placement.metalTile.tile)) == false else {
                return nil
            }
            return placement.placeIn
        }
        let time = frameContext.time
        rise.advance(keys: drawnKeys.compactMap { $0 }, time: time, seconds: extrusion.riseSeconds)

        heightScales.removeAll(keepingCapacity: true)
        var drawnPlacements: [PlaceTile] = []
        var riseByTile: [Tile: Float] = [:]
        var signature: Float = 0
        for (placement, key) in zip(placements, drawnKeys) {
            guard let key, placement.metalTile.tileBuffers.extruded.indicesCount > 0 else {
                heightScales.append(0)
                continue
            }
            drawnPlacements.append(placement)
            let scale = rise.heightScale(of: key, time: time)
            // Kept off zero while the tile draws: the roofs' normals come
            // out of the scaled matrix and are normalized in the shader.
            let drawn = max(scale, 0.001)
            heightScales.append(drawn)
            riseByTile[key.tile] = max(riseByTile[key.tile] ?? 0, scale)
            signature += drawn
        }
        drawsAny = drawnPlacements.isEmpty == false
        frameContext.sharedState.drawnBuildingPlacements = drawnPlacements
        frameContext.sharedState.buildingRiseByTile = riseByTile
        frameContext.sharedState.buildingRiseSignature = signature
        frameContext.sharedState.isExtrusionRising = frameContext.sharedState.isExtrusionRising || rise.isAnimating
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    /// The model tile (`ModelTileStore.tileZoom`) a map tile lies in.
    static func modelTile(over tile: Tile) -> Tile {
        let shift = max(tile.z - ModelTileStore.tileZoom, 0)
        return Tile(x: tile.x >> shift, y: tile.y >> shift, z: tile.z - shift)
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .flat, drawsAny else {
            return
        }

        if layer == .shadowCasters {
            guard let shadowState = frameContext.shadowFrameState else { return }
            // The casters are the building coverage, the same partition the
            // world pass draws, so a building casts exactly once.
            hiddenBuildingIndexBuffers.update(frameContext.sharedState.sceneModelState.replacedBuildings)
            BuildingExtrusionDrawer.drawShadowCasters(
                renderEncoder: encoder,
                lightProjectionView: shadowState.lightProjectionView,
                placeTilesContext: frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext,
                indexBuffers: hiddenBuildingIndexBuffers,
                flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                heightScales: heightScales,
                extrudedTilePipeline: extrudedTilePipeline,
                extrudedDepthState: extrudedDepthState)
            return
        }

        guard layer == .buildingExtrusion else { return }
        drawBuildings(encoder: encoder, frameContext: frameContext)
    }

    func handleMemoryWarning() {}

    func evict() {
        rise.reset()
    }

    private func drawBuildings(encoder: MTLRenderCommandEncoder,
                               frameContext: FrameContext) {
        let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                          shadowMapTexture: shadowMapTextureProvider(),
                                                          fallbackTexture: shadowFallbackTexture)
        hiddenBuildingIndexBuffers.update(frameContext.sharedState.sceneModelState.replacedBuildings)
        GroundFogUniform.bind(GroundFogUniform.resolve(frameContext: frameContext), encoder: encoder)
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: frameContext.cameraUniform,
                                              shadowBinding: shadowBinding,
                                              placeTilesContext: frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext,
                                              indexBuffers: hiddenBuildingIndexBuffers,
                                              flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                              heightScales: heightScales,
                                              extrudedTilePipeline: extrudedTilePipeline,
                                              extrudedStencilTestState: extrudedStencilTestState,
                                              depthDisabledState: depthDisabledState)
    }
}
