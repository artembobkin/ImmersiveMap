// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import ModelTileFormat
import simd

/// Draws the models of the model archive (`ImmersiveMapSettings.modelArchive`):
/// each frame it names the model tiles in and around the view, takes the
/// ones the store has on the GPU, and draws each in the scene models' layer
/// and in the shadow casters'. A tile's models are one mesh in the tile's
/// space, so a tile is one draw under the matrix the map's own buildings of
/// that tile take, and the models lie on the flat map as the buildings do.
/// Like the buildings, they draw on the flat map only.
///
/// The archive holds the models at up to three levels of detail, each in
/// the tiles of one zoom (`ModelTileDetail`), and a frame shows one: the
/// camera zoom's, by the zooms of `ModelArchiveSettings`, read from the
/// frame's settings so a change applies live. Which tiles draw while the
/// camera crosses from one level to the next is `ModelTilePlanner`'s
/// answer: the level on screen stays until the next one is loaded over the
/// same ground.
///
/// What is in view is the map's own answer. The frame's coverage lists the
/// map tiles it draws, and a model tile is wanted when a map tile of its
/// zoom or deeper lies in it, so the models follow the camera exactly as the
/// map does and need no second notion of visibility. The tiles next to
/// those are wanted too: a model reaches over its tile's edge, and its
/// shadow further still.
///
/// A drawn tile names the map buildings its models stand in for
/// (`SceneModelFrameState.replacedBuildings`), and the buildings' drawer
/// leaves those out of the same frame. A tile not yet loaded names nothing,
/// and the buildings stand.
///
/// Runs after the scene models' subsystem, which starts the frame's scene
/// model state over. The labels know nothing of the models.
final class ModelTileRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    /// A model tile a frame wants, in one copy of the world: the flat map
    /// repeats in x, and a tile draws in the copy the view is over.
    struct WantedTile: Hashable {
        let tile: Tile
        let worldWrap: Int8
    }

    let name: String = "ModelTiles"

    /// The tiles around a tile in view that are wanted with it, in tiles.
    static let neighbourRing = 1

    private let store: ModelTileStore?
    private let pipeline: ModelTilePipeline
    private let extrudedDepthState: MTLDepthStencilState
    private let surfaceMaskState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private var drawItems: [ModelTileDrawItem] = []
    private var shadowCasterItems: [ModelTileDrawItem] = []
    /// The models draw from `ModelArchiveSettings.minimumZoom`, each tile
    /// coming up out of the ground (`ExtrusionRise`) over `riseSeconds`
    /// from the frame it is first drawn in: when the camera reaches the
    /// zoom, and when the tile loads later. A tile taking over the ground
    /// of standing models, another level's, keeps their height.
    private let riseSeconds: TimeInterval
    private var rise = ExtrusionRise<WantedTile>()
    /// The level of detail the last frame showed
    /// (`ModelTilePlanner.detail`).
    private var detail: ModelTileDetail?

    /// `store` is nil for a map without a model archive: the subsystem then
    /// does nothing.
    init(store: ModelTileStore?,
         pipeline: ModelTilePipeline,
         extrudedDepthState: MTLDepthStencilState,
         surfaceMaskState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture,
         riseSeconds: TimeInterval = 0) {
        self.store = store
        self.riseSeconds = riseSeconds
        self.pipeline = pipeline
        self.extrudedDepthState = extrudedDepthState
        self.surfaceMaskState = surfaceMaskState
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
    }

    func update(frameContext: FrameContext) {
        drawItems.removeAll(keepingCapacity: true)
        shadowCasterItems.removeAll(keepingCapacity: true)
        guard let store else { return }
        let settings = frameContext.services.settings.modelArchive
        let isRaised = frameContext.renderSurfaceMode == .flat && frameContext.planningZoom >= settings.minimumZoom
        let time = frameContext.time

        let detail = ModelTilePlanner.detail(atZoom: frameContext.planningZoom, current: self.detail, settings: settings)
        self.detail = detail
        let wanted = ModelTilePlanner.tileZoom(of: detail, missingZooms: store.missingZooms).map { zoom in
            Self.wantedTiles(visibleTiles: frameContext.visibleContent.visibleTiles, zoom: zoom)
        } ?? []
        var tiles: [Tile] = []
        var seenTiles = Set<Tile>()
        for wantedTile in wanted where seenTiles.insert(wantedTile.tile).inserted {
            tiles.append(wantedTile.tile)
        }
        let (ready, pending) = store.meshes(for: tiles)
        // Added to the scene models' own count: a capture waits for both.
        frameContext.services.diagnostics.incrementCounter(.pendingSceneModelMeshes, by: pending.count)

        var meshesByTile: [Tile: ModelTileMesh] = [:]
        for mesh in ready {
            meshesByTile[mesh.tile] = mesh
        }
        let readyTiles = Set(meshesByTile.keys)
        let pendingTiles = Set(pending)
        let plan = ModelTilePlanner.plan(wanted: wanted,
                                         state: { tile in
                                             if readyTiles.contains(tile) { return .ready }
                                             return pendingTiles.contains(tile) ? .pending : .absent
                                         },
                                         holdIfLoaded: { tile in
                                             guard let mesh = store.heldMesh(of: tile) else { return false }
                                             meshesByTile[tile] = mesh
                                             return true
                                         })
        // The buildings of these tiles wait for them: a model may stand in
        // for some of them, and they are left out from their first frame.
        frameContext.state[ModelTileFrameState.self].pendingTiles = plan.waiting
        // The tiles are in the flat map's space and draw there alone, as
        // the map's buildings do. Below their zoom they draw nothing and
        // stand in for no building: the buildings, if they draw there,
        // stay whole.
        let drawnTiles = isRaised ? plan.drawn : []
        rise.advance(keys: drawnTiles, time: time, seconds: riseSeconds, overlaps: Self.overlap)
        frameContext.state[ExtrusionRiseFrameState.self].isRising = frameContext.state[ExtrusionRiseFrameState.self].isRising || rise.isAnimating
        guard drawnTiles.isEmpty == false else { return }
        var riseSignature: Float = 0

        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        let frustum = Frustum(pv: frameContext.cameraMatrices.projectionView)
        // The shadow passes cull with the light's frustum (the far window's,
        // which holds the near one): a tile outside the view still casts
        // into it.
        let shadowFrustum = frameContext.shadowFrameState.map { state in
            Frustum(pv: state.casterCullingProjectionView)
        }

        var state = frameContext.state[SceneModelFrameState.self]
        var namedTiles = Set<Tile>()
        for drawnTile in drawnTiles {
            guard let mesh = meshesByTile[drawnTile.tile] else { continue }
            // Drawn, in view or not: its buildings go.
            if namedTiles.insert(mesh.tile).inserted {
                state.replacedBuildings.formUnion(byMapTileZoom: mesh.replacedBuildingIDs)
            }

            let worldWrap = drawnTile.worldWrap
            let placement = Self.placement(of: mesh.tile, worldWrap: worldWrap, flatRenderState: flatRenderState)
            // Coming up out of the ground whole: the tile is lowered by
            // what is left of its tallest model's height, so its models
            // keep their shape and the tallest tops come out first.
            let heightScale = rise.heightScale(of: drawnTile, time: time)
            riseSignature += heightScale
            let depth = (1 - heightScale) * max(Float(mesh.boundsMaximum.z), 0) * placement.scale
            let item = ModelTileDrawItem(mesh: mesh,
                                         modelMatrix: Matrix.translationMatrix(x: 0, y: 0, z: -depth) * placement.modelMatrix
                                             * mesh.positionMatrix,
                                         isRising: heightScale < 1)
            let center = placement.origin + (mesh.boundsMinimum + mesh.boundsMaximum) * 0.5 * placement.scale
                - SIMD3<Float>(0, 0, depth)
            let radius = simd_length(mesh.boundsMaximum - mesh.boundsMinimum) * 0.5 * placement.scale
            guard radius > 0 else { continue }

            if let shadowFrustum, shadowFrustum.isSphereVisible(center: center, radius: radius) {
                shadowCasterItems.append(item)
                state.staticShadowCasters.insert(StaticModelCasterKey(tile: ObjectIdentifier(mesh),
                                                                      worldWrap: worldWrap))
            }
            guard frustum.isSphereVisible(center: center, radius: radius) else { continue }
            drawItems.append(item)
        }
        frameContext.state[ModelTileFrameState.self].riseSignature = riseSignature
        state.hasShadowCasters = state.hasShadowCasters || shadowCasterItems.isEmpty == false
        state.hasDrawnModels = state.hasDrawnModels || drawItems.isEmpty == false
        frameContext.state[SceneModelFrameState.self] = state
    }

    /// Whether two drawn tiles share ground: one of them holds the other,
    /// in the same copy of the world. A tile of one level of detail takes
    /// the height of the tiles of another it comes in over.
    private static func overlap(_ lhs: WantedTile, _ rhs: WantedTile) -> Bool {
        lhs.worldWrap == rhs.worldWrap && lhs.tile.sharesGround(with: rhs.tile)
    }

    /// Where a model tile stands in the frame's flat world: the tile's
    /// south-west corner, the world units a unit of tile space takes, and
    /// the matrix of the two. The same placement the map's own buildings of
    /// the tile take (`BuildingExtrusionDrawer`).
    static func placement(of tile: Tile,
                          worldWrap: Int8,
                          flatRenderState: FlatRenderState) -> (origin: SIMD3<Float>, scale: Float, modelMatrix: matrix_float4x4) {
        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         worldWrap: worldWrap,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / ModelTileContents.tileExtent
        let modelMatrix = Matrix.translationMatrix(x: originAndSize.x, y: originAndSize.y, z: 0)
            * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale)
        return (SIMD3<Float>(originAndSize.x, originAndSize.y, 0), scale, modelMatrix)
    }

    /// The model tiles of `zoom` a frame wants, the zoom of the level of
    /// detail it shows, nearest first: the tile over each map
    /// tile the frame draws at that zoom or deeper, in the
    /// coverage's own order (finest first, which is nearest first), and
    /// after them the ring of tiles around those. A map tile coarser than a
    /// model tile is far from the camera, and its models are not asked for.
    /// A tile keeps the copy of the world its map tile draws in, and a
    /// neighbour across the world's seam is in the copy next to it.
    static func wantedTiles(visibleTiles: [VisibleTile], zoom: Int) -> [WantedTile] {
        let side = 1 << zoom
        var wanted: [WantedTile] = []
        var seen = Set<WantedTile>()
        for visibleTile in visibleTiles where visibleTile.z >= zoom {
            let shift = visibleTile.z - zoom
            let tile = WantedTile(tile: Tile(x: visibleTile.x >> shift, y: visibleTile.y >> shift, z: zoom),
                                  worldWrap: visibleTile.worldWrap)
            if seen.insert(tile).inserted {
                wanted.append(tile)
            }
        }
        let ring = neighbourRing
        for center in wanted {
            for dy in -ring...ring {
                for dx in -ring...ring where dx != 0 || dy != 0 {
                    let y = center.tile.y + dy
                    guard y >= 0, y < side else { continue }
                    // The world wraps in x: past its edge the neighbour is
                    // the first column of the next copy.
                    var x = center.tile.x + dx
                    var worldWrap = Int(center.worldWrap)
                    if x < 0 {
                        x += side
                        worldWrap -= 1
                    } else if x >= side {
                        x -= side
                        worldWrap += 1
                    }
                    guard let wrap = Int8(exactly: worldWrap) else { continue }
                    let neighbour = WantedTile(tile: Tile(x: x, y: y, z: zoom), worldWrap: wrap)
                    if seen.insert(neighbour).inserted {
                        wanted.append(neighbour)
                    }
                }
            }
        }
        return wanted
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.sceneModelsEnabled = builder.sceneModelsEnabled || drawItems.isEmpty == false
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        switch layer {
        case .sceneModels:
            guard drawItems.isEmpty == false else { return }
            let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                              shadowMapTexture: shadowMapTextureProvider(),
                                                              fallbackTexture: shadowFallbackTexture)
            GroundFogUniform.bind(GroundFogUniform.resolveForBuildings(frameContext: frameContext), encoder: encoder)
            // The bias is the frame's settings' at the camera's zoom
            // (`ModelArchiveSettings.depthBias`), read here so the debug
            // panel's drag applies live.
            let depthBias = frameContext.services.settings.modelArchive.depthBias(atZoom: frameContext.planningZoom)
            ModelTileDrawer.draw(renderEncoder: encoder,
                                 cameraUniform: frameContext.cameraUniform,
                                 shadowBinding: shadowBinding,
                                 items: drawItems,
                                 depthBias: depthBias,
                                 pipeline: pipeline,
                                 surfaceMaskState: surfaceMaskState,
                                 depthDisabledState: depthDisabledState)
        case .shadowCasters, .farShadowCasters:
            guard let slot = ShadowCascadeSlot(casterLayer: layer),
                  let lightProjectionView = frameContext.shadowFrameState?.lightProjectionView(for: slot),
                  shadowCasterItems.isEmpty == false else { return }
            ModelTileDrawer.drawShadowCasters(renderEncoder: encoder,
                                              lightProjectionView: lightProjectionView,
                                              items: shadowCasterItems,
                                              pipeline: pipeline,
                                              extrudedDepthState: extrudedDepthState)
        default:
            return
        }
    }

    func handleMemoryWarning() {
        store?.handleMemoryWarning()
    }
}
