// Copyright (c) 2025-2026 Artem Bobkin.
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

    /// The immutable GPU resources of the process, each feature's set
    /// under its own type (`SharedRenderResources.get`). Everything else
    /// here is made per renderer.
    let shared: SharedRenderResources

    // MARK: - Scene Resources

    let globeCapRenderer: GlobeCapRenderer
    /// What no tile paints, as the style states it.
    let baseColors: ImmersiveMapBaseColors
    /// The caps' rim colour, baked per view from its own placements.
    let starfieldRenderer: StarfieldRenderer
    /// The horizon layer's drawer; its pipeline is shared.
    let horizonRenderer: HorizonRenderer
    let flatTileOriginCalculator: FlatTileOriginCalculator

    // MARK: - Tile and Label Resources

    let tileRenderStore: TileRenderStore
    let baseLabelCache: BaseLabelCache
    let roadLabelCache: RoadLabelCache

    // MARK: - Scene Model Resources

    let sceneModelSource: SceneModelRenderSource
    let sceneModelMeshStore: SceneModelMeshStore
    /// The models of the model archive, nil for a map without one.
    let modelTileStore: ModelTileStore?
    /// The ground relief: the terrain the flattened ground rises by and
    /// the state the frames draw it by, nil while the relief is off
    /// (`TileSettings.GroundReliefSettings`).
    let groundRelief: GroundReliefFrameState?
    /// The trees of the woods and the parks: their model and their
    /// pipeline (`TreeRenderSubsystem`).
    let treeModelStore: TreeModelStore
    /// The colours of the trees, as the style states them.
    let treePalette: ImmersiveMapTreePalette
    /// How opaque the names and the POIs are by the zoom, the style's
    /// (`ImmersiveMapLabelOpacity`), which the frame reads at its zoom.
    let labelOpacity: ImmersiveMapLabelOpacity
    /// The layers of the app's data: where the frame reads them from, what
    /// they are on the GPU and their pipelines (`LayerRenderSubsystem`).
    let layerSource: LayerRenderSource
    let layerMeshStore: LayerMeshStore
    /// The tile grid: where the frame reads the app's side of it from, and
    /// its pipelines (`TileGridRenderSubsystem`).
    let tileGridSource: TileGridRenderSource

    // MARK: - Pin and Debug Resources

    let pinSource: PinRenderSource
    let annotationSource: AnnotationRenderSource
    let pinsRenderer: PinsRenderer
    let debugOverlayRenderer: DebugOverlayRenderer
    let tileTraceRecorder: TileTraceRecorder
    let baseLabelTraceRecorder: BaseLabelTraceRecorder
    let tileLoadingStatusReporter: TileLoadingStatusReporter?

    // MARK: - Initialization

    @MainActor
    init(layer: CAMetalLayer,
         pinSource: PinRenderSource,
         annotationSource: AnnotationRenderSource,
         sceneModelSource: SceneModelRenderSource,
         layerSource: LayerRenderSource,
         tileGridSource: TileGridRenderSource = EmptyTileGridRenderSource(),
         styleRuntime: MapStyleRuntime,
         config: ImmersiveMapSettings,
         eventSink: RenderFrameEventSink,
         tileTraceRecorder: TileTraceRecorder,
         baseLabelTraceRecorder: BaseLabelTraceRecorder) throws {
        let shared = try SharedRenderResources.shared(sampleCount: config.postProcessing.multisampleCount)
        let metal = RendererSetup.buildMetal(layer: layer, sharedResources: shared)
        self.shared = shared
        self.metalContext = metal
        self.tileTraceRecorder = tileTraceRecorder
        self.baseLabelTraceRecorder = baseLabelTraceRecorder
        self.tileLoadingStatusReporter = config.debug.enableDebugPanel ? TileLoadingStatusReporter() : nil

        self.baseColors = styleRuntime.baseColors

        // The starfield renderer bakes the star-generation settings, so it
        // stays per renderer. Only its pipeline is shared.
        self.starfieldRenderer = StarfieldRenderer(metalDevice: metal.device,
                                                   pipeline: shared.get(StarfieldPipeline.self),
                                                   config: config.scene.starfield)

        self.horizonRenderer = HorizonRenderer(pipeline: shared.get(HorizonSharedResources.self).pipeline)

        self.flatTileOriginCalculator = FlatTileOriginCalculator(metalDevice: metal.device)
        // The cap palette bakes style colors. Grids and pipeline come from
        // the shared set.
        self.globeCapRenderer = GlobeCapRenderer(sharedResources: shared.get(GlobeCapRenderer.SharedResources.self),
                                                 maxLatitude: ImmersiveMapProjection.maxMercatorLatitude,
                                                 baseColors: styleRuntime.baseColors)
        self.tileRenderStore = TileRenderStore(styleRuntime: styleRuntime,
                                               metalDevice: metal.device,
                                               textLayout: shared.get(TextAtlas.self).layout,
                                               config: config,
                                               tileTraceRecorder: tileTraceRecorder,
                                               tileLoadingStatusReporter: tileLoadingStatusReporter)
        self.tileRenderStore.eventSink = eventSink
        self.baseLabelCache = BaseLabelCache(metalDevice: metal.device)
        // On the relief the labels' paths are cut where the roads' ribbons
        // were, so the names ride the relief with the roads.
        let parseOptions = TileParseOptions(settings: config)
        self.roadLabelCache = RoadLabelCache(metalDevice: metal.device,
                                             reliefSubdivisionStep: { parseOptions.reliefSubdivisionStep(tileZoom: $0) })

        self.sceneModelSource = sceneModelSource
        self.sceneModelMeshStore = SceneModelMeshStore(device: metal.device)
        self.sceneModelMeshStore.eventSink = eventSink
        self.modelTileStore = ModelTileStore.make(settings: config,
                                                  device: metal.device,
                                                  schema: styleRuntime.schema)
        self.modelTileStore?.eventSink = eventSink
        self.groundRelief = GroundReliefFrameState.make(settings: config,
                                                        hillshade: styleRuntime.hillshade,
                                                        occlusion: styleRuntime.terrainOcclusion,
                                                        device: metal.device)
        self.groundRelief?.store.eventSink = eventSink
        self.treePalette = styleRuntime.treePalette
        self.labelOpacity = styleRuntime.labelOpacity
        self.treeModelStore = TreeModelStore(device: metal.device)
        self.treeModelStore.eventSink = eventSink
        self.layerSource = layerSource
        self.tileGridSource = tileGridSource
        self.layerMeshStore = LayerMeshStore(device: metal.device)
        self.layerMeshStore.eventSink = eventSink

        self.pinSource = pinSource
        self.annotationSource = annotationSource
        self.pinsRenderer = PinsRenderer(metalDevice: metal.device,
                                               sharedResources: shared.get(PinsRenderer.SharedResources.self),
                                               config: config.pins)
        self.debugOverlayRenderer = DebugOverlayRenderer(metalDevice: metal.device,
                                                         textPipeline: shared.get(TextPipeline.self),
                                                         settings: config.debug)
    }

    // MARK: - Settings

    func applySettings(_ settings: ImmersiveMapSettings) {
        debugOverlayRenderer.apply(settings: settings.debug)
    }

}
