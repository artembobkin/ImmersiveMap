// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit
import QuartzCore

/// Long-lived renderer lifecycle context: gathers Metal resources, caches and renderer services
/// reused by the subsystem graph and frame pipeline across frames.
final class RenderPersistentContext {
    // MARK: - Metal Core

    let metalContext: RenderMetalContext

    // MARK: - Pipelines

    let polygonPipeline: PolygonsPipeline
    let tilePipeline: TilePipeline
    let globeTileTexturePipeline: TilePipeline
    let extrudedTilePipeline: ExtrudedTilePipeline
    let globePipeline: GlobePipeline
    let fxaaPipeline: FXAAPipeline

    // MARK: - Scene Resources

    let globeCapRenderer: GlobeCapRenderer
    let starfieldRenderer: StarfieldRenderer
    let mapSurfaceGridBuffers: MapSurfaceGridBuffers
    let flatTileOriginCalculator: FlatTileOriginCalculator
    let extrudedDepthState: MTLDepthStencilState
    let globeCapDepthState: MTLDepthStencilState
    let depthDisabledState: MTLDepthStencilState
    /// Bound at the shadow-map slot when the shadow pass is skipped: receiver
    /// shaders reference the texture statically and Metal validation requires a
    /// bound depth texture even though strength = 0 skips the sampling branch.
    /// Depth textures cannot be filled from the CPU, so a one-time no-draw pass
    /// clears this 1x1 texture to 1.0 ("lit everywhere") at init.
    let shadowFallbackTexture: MTLTexture

    // MARK: - Tile and Label Resources

    let tileRenderStore: TileRenderStore
    let tilesTexture: TileAtlasTexture
    let textRenderer: TextRenderer
    let poiSpriteAtlas: PoiSpriteAtlas
    let baseLabelCache: BaseLabelCache
    let roadLabelCache: RoadLabelCache

    // MARK: - Scene Model Resources

    let sceneModelSource: SceneModelRenderSource
    let sceneModelMeshStore: SceneModelMeshStore
    let sceneModelPipeline: SceneModelPipeline

    // MARK: - Avatar and Debug Resources

    let avatarSource: AvatarRenderSource
    let markerSource: MarkerRenderSource
    let avatarsRenderer: AvatarsRenderer
    let debugOverlayRenderer: DebugOverlayRenderer
    let tileTraceRecorder: TileTraceRecorder
    let baseLabelTraceRecorder: BaseLabelTraceRecorder
    let tileLoadingStatusReporter: TileLoadingStatusReporter?

    // MARK: - Initialization

    init(layer: CAMetalLayer,
         avatarSource: AvatarRenderSource,
         markerSource: MarkerRenderSource,
         sceneModelSource: SceneModelRenderSource,
         providerRuntime: ImmersiveMapProviderRuntimeContext,
         config: ImmersiveMapSettings,
         eventSink: RenderFrameEventSink,
         tileTraceRecorder: TileTraceRecorder,
         baseLabelTraceRecorder: BaseLabelTraceRecorder) {
        let metal = RendererSetup.buildMetal(layer: layer)
        self.metalContext = metal
        self.tileTraceRecorder = tileTraceRecorder
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.tileLoadingStatusReporter = config.debug.enableDebugPanel ? TileLoadingStatusReporter() : nil

        self.extrudedDepthState = metal.device.makeDepthStencilState(descriptor: Self.makeSceneDepthDescriptor())!
        self.globeCapDepthState = metal.device.makeDepthStencilState(descriptor: Self.makeGlobeCapDepthDescriptor())!
        self.depthDisabledState = metal.device.makeDepthStencilState(descriptor: Self.makeDepthDisabledDescriptor())!
        self.shadowFallbackTexture = Self.makeShadowFallbackTexture(metalContext: metal)

        let mapBaseColors = providerRuntime.mapBaseColors

        let pipelineFactory = RenderPipelineFactory(metalContext: metal,
                                                    layer: layer,
                                                    config: config)
        let pipelines = pipelineFactory.makeRenderPipelines()
        self.polygonPipeline = pipelines.polygonPipeline
        self.tilePipeline = pipelines.tilePipeline
        self.globeTileTexturePipeline = pipelines.globeTileTexturePipeline
        self.extrudedTilePipeline = pipelines.extrudedTilePipeline
        self.globePipeline = pipelines.globePipeline
        self.fxaaPipeline = pipelines.fxaaPipeline
        self.starfieldRenderer = pipelines.starfieldRenderer

        self.mapSurfaceGridBuffers = RendererSetup.makeMapSurfaceGridBuffers(metalDevice: metal.device)
        self.flatTileOriginCalculator = FlatTileOriginCalculator(metalDevice: metal.device)
        self.globeCapRenderer = GlobeCapRenderer(metalDevice: metal.device,
                                                 layer: layer,
                                                 library: metal.library,
                                                 sampleCount: metal.renderSampleCount,
                                                 maxLatitude: WebMercatorMath.maxLatitudeRadians,
                                                 mapBaseColors: mapBaseColors)
        self.textRenderer = TextRenderer(device: metal.device,
                                         library: metal.library,
                                         sampleCount: 1)
        self.poiSpriteAtlas = PoiSpriteAtlas(device: metal.device)
        self.tilesTexture = TileAtlasTexture(metalDevice: metal.device,
                                              tilePipeline: globeTileTexturePipeline,
                                              shadowFallbackTexture: shadowFallbackTexture,
                                              mapBaseColors: mapBaseColors)
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
        self.sceneModelPipeline = SceneModelPipeline(metalDevice: metal.device,
                                                     layer: layer,
                                                     library: metal.library,
                                                     sampleCount: metal.renderSampleCount)

        self.avatarSource = avatarSource
        self.markerSource = markerSource
        self.avatarsRenderer = AvatarsRenderer(metalDevice: metal.device,
                                               layer: layer,
                                               library: metal.library,
                                               sampleCount: 1,
                                               config: config.avatars)
        self.debugOverlayRenderer = DebugOverlayRenderer(metalDevice: metal.device, settings: config.debug)
    }

    // MARK: - Settings

    func applySettings(_ settings: ImmersiveMapSettings) {
        debugOverlayRenderer.apply(settings: settings.debug)
    }

    // MARK: - Shadow Fallback

    private static func makeShadowFallbackTexture(metalContext: RenderMetalContext) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = metalContext.device.makeTexture(descriptor: descriptor)!
        texture.label = "ShadowFallbackTexture"

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.depthAttachment.texture = texture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .store
        passDescriptor.depthAttachment.clearDepth = 1.0
        if let commandBuffer = metalContext.makeCommandBuffer(),
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            encoder.endEncoding()
            commandBuffer.commit()
        }
        return texture
    }

    // MARK: - Depth States

    private static func makeSceneDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    private static func makeGlobeCapDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }

    private static func makeDepthDisabledDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        return descriptor
    }
}
