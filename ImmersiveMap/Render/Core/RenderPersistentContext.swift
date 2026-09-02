// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit
import QuartzCore

/// Long-lived renderer lifecycle context: gathers Metal resources, caches and renderer services
/// reused by the subsystem graph and frame pipeline across frames.
/// Immutable GPU resources (library, pipelines, atlases, static geometry) come
/// from the process-wide ``SharedRenderResources`` and are only referenced
/// here; everything mutable is created per renderer.
final class RenderPersistentContext {
    // MARK: - Metal Core

    let metalContext: RenderMetalContext

    // MARK: - Pipelines

    let polygonPipeline: PolygonsPipeline
    let tilePipeline: TilePipeline
    let globeVectorSurfacePipeline: TilePipeline
    let extrudedTilePipeline: ExtrudedTilePipeline
    let groundShadowMaskPipeline: GroundShadowMaskPipeline
    let fxaaPipeline: FXAAPipeline
    let tilePointScreenPipelines: TilePointScreenPipelines
    let roadLabelPlacementPipeline: RoadLabelPlacementPipeline

    // MARK: - Scene Resources

    let globeCapRenderer: GlobeCapRenderer
    /// The caps' rim colour, baked per view from its own placements.
    let starfieldRenderer: StarfieldRenderer
    let atmosphereRenderer: AtmosphereRenderer
    let flatTileOriginCalculator: FlatTileOriginCalculator
    let extrudedDepthState: MTLDepthStencilState
    let globeCapDepthState: MTLDepthStencilState
    /// See `SharedRenderResources.skyBackdropDepthState`.
    let skyBackdropDepthState: MTLDepthStencilState
    let depthDisabledState: MTLDepthStencilState
    /// See `SharedRenderResources.groundDepthState`.
    let groundDepthState: MTLDepthStencilState
    /// The tile-priority stencil states; see SharedRenderResources.
    let sphereOpaqueOwnerState: MTLDepthStencilState
    let groundOwnerState: MTLDepthStencilState
    let tileStencilTestState: MTLDepthStencilState
    /// See `SharedRenderResources.compositeDepthResetState`.
    let compositeDepthResetState: MTLDepthStencilState
    /// See `SharedRenderResources.supportsFramebufferFetch`.
    let supportsFramebufferFetch: Bool
    /// Bound at the shadow-map slot when the shadow pass is skipped: receiver
    /// shaders reference the texture statically and Metal validation requires a
    /// bound depth texture even though strength = 0 skips the sampling branch.
    /// Depth textures cannot be filled from the CPU, so a one-time no-draw pass
    /// clears this 1x1 texture to 1.0 ("lit everywhere") at init.
    let shadowFallbackTexture: MTLTexture
    /// See `SharedRenderResources.groundShadowMaskFallbackTexture`.
    let groundShadowMaskFallbackTexture: MTLTexture

    // MARK: - Tile and Label Resources

    let tileRenderStore: TileRenderStore
    let textRenderer: TextRenderer
    let poiSpriteAtlas: PoiSpriteAtlas
    let baseLabelCache: BaseLabelCache
    let roadLabelCache: RoadLabelCache

    // MARK: - Scene Model Resources

    let sceneModelSource: SceneModelRenderSource
    let sceneModelMeshStore: SceneModelMeshStore
    let sceneModelPipeline: SceneModelPipeline

    // MARK: - Route Resources

    let routeSource: RouteRenderSource
    let routePipeline: RoutePipeline

    // MARK: - Avatar and Debug Resources

    let avatarSource: AvatarRenderSource
    let markerSource: MarkerRenderSource
    let avatarsRenderer: AvatarsRenderer
    let debugOverlayRenderer: DebugOverlayRenderer
    let tileTraceRecorder: TileTraceRecorder
    let baseLabelTraceRecorder: BaseLabelTraceRecorder
    let tileLoadingStatusReporter: TileLoadingStatusReporter?

    // MARK: - Initialization

    @MainActor
    init(layer: CAMetalLayer,
         avatarSource: AvatarRenderSource,
         markerSource: MarkerRenderSource,
         sceneModelSource: SceneModelRenderSource,
         routeSource: RouteRenderSource,
         providerRuntime: ImmersiveMapProviderRuntimeContext,
         config: ImmersiveMapSettings,
         eventSink: RenderFrameEventSink,
         tileTraceRecorder: TileTraceRecorder,
         baseLabelTraceRecorder: BaseLabelTraceRecorder) {
        let shared = SharedRenderResources.shared()
        let metal = RendererSetup.buildMetal(layer: layer, sharedResources: shared)
        self.metalContext = metal
        self.tileTraceRecorder = tileTraceRecorder
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.tileLoadingStatusReporter = config.debug.enableDebugPanel ? TileLoadingStatusReporter() : nil

        self.extrudedDepthState = shared.extrudedDepthState
        self.globeCapDepthState = shared.globeCapDepthState
        self.skyBackdropDepthState = shared.skyBackdropDepthState
        self.depthDisabledState = shared.depthDisabledState
        self.groundDepthState = shared.groundDepthState
        self.sphereOpaqueOwnerState = shared.sphereOpaqueOwnerState
        self.groundOwnerState = shared.groundOwnerState
        self.tileStencilTestState = shared.tileStencilTestState
        self.compositeDepthResetState = shared.compositeDepthResetState
        self.supportsFramebufferFetch = shared.supportsFramebufferFetch
        self.shadowFallbackTexture = shared.shadowFallbackTexture
        self.groundShadowMaskFallbackTexture = shared.groundShadowMaskFallbackTexture

        let mapBaseColors = providerRuntime.mapBaseColors

        self.routeSource = routeSource
        self.routePipeline = shared.routePipeline

        self.polygonPipeline = shared.polygonPipeline
        self.tilePipeline = shared.tilePipeline
        self.globeVectorSurfacePipeline = shared.globeVectorSurfacePipeline
        self.extrudedTilePipeline = shared.extrudedTilePipeline
        self.groundShadowMaskPipeline = shared.groundShadowMaskPipeline
        self.fxaaPipeline = shared.fxaaPipeline
        self.tilePointScreenPipelines = shared.tilePointScreenPipelines
        self.roadLabelPlacementPipeline = shared.roadLabelPlacementPipeline
        // The starfield renderer bakes the star-generation settings, so it
        // stays per renderer; only its pipeline is shared.
        self.starfieldRenderer = StarfieldRenderer(metalDevice: metal.device,
                                                   pipeline: shared.starfieldPipeline,
                                                   config: config.scene.starfield)
        self.atmosphereRenderer = AtmosphereRenderer(pipeline: shared.atmospherePipeline)

        self.flatTileOriginCalculator = FlatTileOriginCalculator(metalDevice: metal.device)
        // The cap palette bakes style colors; grids and pipeline come from
        // the shared set.
        self.globeCapRenderer = GlobeCapRenderer(sharedResources: shared.globeCap,
                                                 maxLatitude: WebMercatorMath.maxLatitudeRadians,
                                                 mapBaseColors: mapBaseColors)
        self.textRenderer = shared.textRenderer
        self.poiSpriteAtlas = shared.poiSpriteAtlas
        self.tileRenderStore = TileRenderStore(providerRuntime: providerRuntime,
                                               metalDevice: metal.device,
                                               textRenderer: textRenderer,
                                               config: config,
                                               tileTraceRecorder: tileTraceRecorder,
                                               tileLoadingStatusReporter: tileLoadingStatusReporter)
        self.tileRenderStore.eventSink = eventSink
        self.baseLabelCache = BaseLabelCache(metalDevice: metal.device)
        self.roadLabelCache = RoadLabelCache(metalDevice: metal.device,
                                             textRenderer: textRenderer)

        self.sceneModelSource = sceneModelSource
        self.sceneModelMeshStore = SceneModelMeshStore(device: metal.device)
        self.sceneModelMeshStore.eventSink = eventSink
        self.sceneModelPipeline = shared.sceneModelPipeline

        self.avatarSource = avatarSource
        self.markerSource = markerSource
        self.avatarsRenderer = AvatarsRenderer(metalDevice: metal.device,
                                               sharedResources: shared.avatars,
                                               config: config.avatars)
        self.debugOverlayRenderer = DebugOverlayRenderer(metalDevice: metal.device, settings: config.debug)
    }

    // MARK: - Settings

    func applySettings(_ settings: ImmersiveMapSettings) {
        debugOverlayRenderer.apply(settings: settings.debug)
    }

}
