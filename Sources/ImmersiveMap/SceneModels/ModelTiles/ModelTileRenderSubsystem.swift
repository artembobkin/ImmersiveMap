// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Draws the models of the model archive (`ImmersiveMapSettings.modelArchive`):
/// each frame it names the model tiles in and around the view, takes the
/// ones the store has on the GPU, and draws each in the scene models' layer
/// and in the shadow casters'. A tile's models are one mesh in the tile's
/// space, so a tile is one draw under the matrix the map's own buildings of
/// that tile take, and the models lie on the flat map as the buildings do.
/// Like the buildings, they draw on the flat map only.
///
/// What is in view is the map's own answer. The frame's coverage lists the
/// map tiles it draws, and a model tile is wanted when a map tile of its
/// zoom or deeper lies in it, so the models follow the camera exactly as the
/// map does and need no second notion of visibility. The tiles next to
/// those are wanted too: a model reaches over its tile's edge, and its
/// shadow further still.
///
/// A tile draws as soon as it is loaded, whatever the camera's zoom: which
/// tiles are loaded is the only rule, and that is the map's coverage. A
/// loaded tile names the map buildings its models stand in for
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
    private let groundCutStates: SceneModelGroundCutStates
    private let depthDisabledState: MTLDepthStencilState
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture
    private var drawItems: [ModelTileDrawItem] = []
    private var shadowCasterItems: [ModelTileDrawItem] = []

    /// `store` is nil for a map without a model archive: the subsystem then
    /// does nothing.
    init(store: ModelTileStore?,
         pipeline: ModelTilePipeline,
         extrudedDepthState: MTLDepthStencilState,
         surfaceMaskState: MTLDepthStencilState,
         groundCutStates: SceneModelGroundCutStates,
         depthDisabledState: MTLDepthStencilState,
         shadowMapTextureProvider: @escaping () -> MTLTexture?,
         shadowFallbackTexture: MTLTexture) {
        self.store = store
        self.pipeline = pipeline
        self.extrudedDepthState = extrudedDepthState
        self.surfaceMaskState = surfaceMaskState
        self.groundCutStates = groundCutStates
        self.depthDisabledState = depthDisabledState
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
    }

    func update(frameContext: FrameContext) {
        drawItems.removeAll(keepingCapacity: true)
        shadowCasterItems.removeAll(keepingCapacity: true)
        guard let store else { return }

        let wanted = Self.wantedTiles(visibleTiles: frameContext.visibleContent.visibleTiles)
        var wrapsByTile: [Tile: [Int8]] = [:]
        var tiles: [Tile] = []
        for wantedTile in wanted {
            if wrapsByTile[wantedTile.tile] == nil {
                tiles.append(wantedTile.tile)
            }
            wrapsByTile[wantedTile.tile, default: []].append(wantedTile.worldWrap)
        }
        let (meshes, pendingCount) = store.meshes(for: tiles)
        // Added to the scene models' own count: a capture waits for both.
        frameContext.services.diagnostics.incrementCounter(.pendingSceneModelMeshes, by: pendingCount)
        // The tiles are in the flat map's space and draw there alone, as
        // the map's buildings do.
        guard meshes.isEmpty == false, frameContext.renderSurfaceMode == .flat else { return }

        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        let frustum = Frustum(pv: frameContext.cameraMatrices.projectionView)
        // The shadow pass culls with the light's frustum: a tile outside
        // the view still casts into it.
        let shadowFrustum = frameContext.shadowFrameState.map { state in
            Frustum(pv: state.lightProjectionView)
        }

        var state = frameContext.sharedState.sceneModelState
        for mesh in meshes {
            // Loaded, so shown, in view or not: its buildings go.
            state.replacedBuildings.formUnion(byMapTileZoom: mesh.replacedBuildingIDs)

            for worldWrap in wrapsByTile[mesh.tile] ?? [] {
                let placement = Self.placement(of: mesh.tile, worldWrap: worldWrap, flatRenderState: flatRenderState)
                let item = ModelTileDrawItem(mesh: mesh, modelMatrix: placement.modelMatrix)
                let center = placement.origin + (mesh.boundsMinimum + mesh.boundsMaximum) * 0.5 * placement.scale
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
        }
        state.hasShadowCasters = state.hasShadowCasters || shadowCasterItems.isEmpty == false
        state.hasDrawnModels = state.hasDrawnModels || drawItems.isEmpty == false
        frameContext.sharedState.sceneModelState = state
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

    /// The model tiles a frame wants, nearest first: the tile over each map
    /// tile the frame draws at the model tiles' zoom or deeper, in the
    /// coverage's own order (finest first, which is nearest first), and
    /// after them the ring of tiles around those. A map tile coarser than a
    /// model tile is far from the camera, and its models are not asked for.
    /// A tile keeps the copy of the world its map tile draws in, and a
    /// neighbour across the world's seam is in the copy next to it.
    static func wantedTiles(visibleTiles: [VisibleTile]) -> [WantedTile] {
        let zoom = ModelTileStore.tileZoom
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

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        switch layer {
        case .sceneModels:
            guard drawItems.isEmpty == false else { return }
            let shadowBinding = ShadowReceiverBinding.resolve(frameContext: frameContext,
                                                              shadowMapTexture: shadowMapTextureProvider(),
                                                              fallbackTexture: shadowFallbackTexture)
            ModelTileDrawer.draw(renderEncoder: encoder,
                                 cameraUniform: frameContext.cameraUniform,
                                 shadowBinding: shadowBinding,
                                 items: drawItems,
                                 pipeline: pipeline,
                                 surfaceMaskState: surfaceMaskState,
                                 groundCutStates: groundCutStates,
                                 depthDisabledState: depthDisabledState)
        case .shadowCasters:
            guard let shadowState = frameContext.shadowFrameState,
                  shadowCasterItems.isEmpty == false else { return }
            ModelTileDrawer.drawShadowCasters(renderEncoder: encoder,
                                              lightProjectionView: shadowState.lightProjectionView,
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

    func evict() {
        store?.evict()
    }
}
