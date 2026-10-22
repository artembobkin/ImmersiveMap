// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Draws the trees of the flat map's woods and parks: the engine's tree
/// model (`TreeModelStore`), instanced over each tile's trees
/// (`TreeInstance`, placed by the parser), opaque into the world pass
/// with the buildings. The trees draw from the tiles the buildings draw
/// from (`TreeCoveragePlanner`, `BuildingCoveragePlanner`), from the
/// camera zoom the settings name (`TreeSettings.minimumZoom`), and rise
/// out of the ground with the buildings (`ExtrusionRise`). Below
/// `TreeSettings.fullDensityZoom` a tile draws a prefix of its trees,
/// which are sorted by priority, so the trees thin evenly with the
/// distance and a far zoom's trees are among a near zoom's. The trees
/// stand on the plane: at their zooms the ground relief is not drawn.
///
/// Their shadows are not the shadow map's: each tree lays a soft disc on
/// the ground under its crown, moved away from the sun and stretched
/// along it (Trees.metal), drawn in the roads' layer after the roads so
/// it lies over them, with the shadow map's darkening and tint, and not
/// at all while the shadows are off. Runs after the ground's subsystems
/// for that.
final class TreeRenderSubsystem: RenderSubsystem {
    let name: String = "Trees"

    private let modelStore: TreeModelStore
    private let pipeline: TreePipeline
    /// The colours the model is drawn in (`ImmersiveMapTreePalette`).
    private let palette: ImmersiveMapTreePalette
    /// World-pass trees: scene depth plus the tile-priority stencil test,
    /// raising the surface mask bit where a tree stands, as a building.
    private let stencilTestState: MTLDepthStencilState
    /// The shadow discs: the ground's depth test, so a disc stays off a
    /// building standing nearer than the ground it lies on, no writes.
    private let groundDepthState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let settings: ImmersiveMapSettings.TreeSettings
    private let riseSeconds: TimeInterval
    private var rise = ExtrusionRise<VisibleTile>()
    private var items: [TreeDrawer.Item] = []
    private var level = 0

    init(modelStore: TreeModelStore,
         pipeline: TreePipeline,
         palette: ImmersiveMapTreePalette,
         stencilTestState: MTLDepthStencilState,
         groundDepthState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         settings: ImmersiveMapSettings.TreeSettings,
         riseSeconds: TimeInterval) {
        self.modelStore = modelStore
        self.pipeline = pipeline
        self.palette = palette
        self.stencilTestState = stencilTestState
        self.groundDepthState = groundDepthState
        self.depthDisabledState = depthDisabledState
        self.settings = settings
        self.riseSeconds = riseSeconds
    }

    func update(frameContext: FrameContext) {
        let zoom = frameContext.planningZoom
        let isRaised = settings.isEnabled
            && frameContext.renderSurfaceMode == .flat
            && zoom >= settings.minimumZoom
        let placements = frameContext.sharedState.tilePlacementState.buildingPlaceTilesContext.tilePlacements
        let drawnKeys: [VisibleTile?] = placements.map { placement in
            guard isRaised, placement.metalTile.tileBuffers.treesCount > 0 else { return nil }
            return placement.placeIn
        }
        let time = frameContext.time
        rise.advance(keys: drawnKeys.compactMap { $0 },
                     time: time,
                     seconds: riseSeconds,
                     overlaps: Self.overlap)
        // The share of a tile's trees drawn at this zoom: all from the
        // full-density zoom, halving with every zoom below it.
        let share = Float(min(1, pow(2.0, zoom - settings.fullDensityZoom)))
        level = zoom >= settings.nearDetailZoom ? 0 : 1

        items.removeAll(keepingCapacity: true)
        for (index, placement) in placements.enumerated() {
            guard let key = drawnKeys[index] else { continue }
            let scale = rise.heightScale(of: key, time: time)
            guard scale > 0 else { continue }
            let count = placement.metalTile.tileBuffers.treesCount
            let drawn = min(count, max(Int((Float(count) * share).rounded(.up)), 1))
            items.append(TreeDrawer.Item(placement: placement, instanceCount: drawn, riseScale: scale))
        }
        frameContext.sharedState.isExtrusionRising = frameContext.sharedState.isExtrusionRising || rise.isAnimating
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    /// Whether two squares share ground: one of them holds the other, in
    /// the same world copy.
    private static func overlap(_ lhs: VisibleTile, _ rhs: VisibleTile) -> Bool {
        guard lhs.worldWrap == rhs.worldWrap else { return false }
        let (coarse, fine) = lhs.z <= rhs.z ? (lhs, rhs) : (rhs, lhs)
        return fine.tile.findParentTile(atZoom: coarse.z) == coarse.tile
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .flat,
              items.isEmpty == false,
              let mesh = modelStore.mesh else {
            return
        }
        let lightDirection = frameContext.services.settings.scene.light.direction
        switch layer {
        case .buildingExtrusion:
            GroundFogUniform.bind(GroundFogUniform.resolveForBuildings(frameContext: frameContext), encoder: encoder)
            TreeDrawer.draw(renderEncoder: encoder,
                            cameraUniform: frameContext.cameraUniform,
                            items: items,
                            mesh: mesh,
                            level: level,
                            palette: palette,
                            flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                            lightDirection: lightDirection,
                            pipeline: pipeline,
                            stencilTestState: stencilTestState,
                            depthDisabledState: depthDisabledState)
        case .flatMapRoads:
            // The discs lie on the ground, so they fade into the fog as
            // the ground does, not as the buildings do.
            guard let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext) else { return }
            GroundFogUniform.bind(GroundFogUniform.resolve(frameContext: frameContext), encoder: encoder)
            TreeDrawer.drawShadows(renderEncoder: encoder,
                                   cameraUniform: frameContext.cameraUniform,
                                   shadowUniform: shadowState.shadowUniform,
                                   items: items,
                                   mesh: mesh,
                                   palette: palette,
                                   flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                                   lightDirection: lightDirection,
                                   pipeline: pipeline,
                                   groundDepthState: groundDepthState,
                                   depthDisabledState: depthDisabledState)
        default:
            return
        }
    }

    func handleMemoryWarning() {}

    func evict() {
        rise.reset()
    }
}
