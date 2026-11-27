// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

enum RenderGraphFactory {
    /// The shared GPU resources of the features, one set per type: what
    /// `SharedRenderResources` builds once for the process, side by side,
    /// and what `makeDefaultGraph` hands the subsystems. A feature with
    /// shared resources adds its set here and nowhere else in `Render`.
    /// The heaviest sets go first, so they overlap the whole batch.
    static var sharedResourceTypes: [any SharedGPUResources.Type] {
        [
            TextAtlas.self,
            LabelPipelines.self,
            TextPipeline.self,
            PinsRenderer.SharedResources.self,
            GlobeCapRenderer.SharedResources.self,
            ExtrudedTilePipeline.self,
            PolygonsPipeline.self,
            FlatGroundSharedResources.self,
            ShadowSharedResources.self,
            RasterTilePipeline.self,
            GlobeVectorSurfaceSharedResources.self,
            SurfaceLabelPipeline.self,
            FXAAPipeline.self,
            StarfieldPipeline.self,
            HorizonSharedResources.self,
            SceneModelSharedResources.self,
            ModelTilePipeline.self,
            PlacementStencilSharedResources.self,
            TreePipeline.self,
            LayerPipeline.self,
            TileGridPipeline.self,
            CommonDepthStates.self,
            TilePriorityDepthStates.self,
            RoadLabelSharedResources.self
        ]
    }

    /// The shared sets that are made on the main thread, after the others.
    static var mainThreadSharedResourceTypes: [any MainThreadSharedGPUResources.Type] {
        [PoiSpriteAtlas.self]
    }

    static func makeDefaultGraph(context: RenderPersistentContext,
                                 settings: ImmersiveMapSettings,
                                 debugOverlayControls: DebugOverlayControlState,
                                 postProcessingInputTextureProvider: @escaping () -> MTLTexture?,
                                 shadowMapTextureProvider: @escaping () -> MTLTexture?,
                                 groundShadowMaskTextureProvider: @escaping () -> MTLTexture?) -> RenderGraph {
        // The sets of the process, each read once and handed to the
        // subsystems that draw by it.
        let shared = context.shared
        let depth = shared.get(CommonDepthStates.self)
        let tileDepth = shared.get(TilePriorityDepthStates.self)
        let shadows = shared.get(ShadowSharedResources.self)
        let sceneModels = shared.get(SceneModelSharedResources.self)
        let placement = shared.get(PlacementStencilSharedResources.self)
        let horizon = shared.get(HorizonSharedResources.self)
        let textAtlas = shared.get(TextAtlas.self)
        let labelPipelines = shared.get(LabelPipelines.self)
        let tileWorkingSetSubsystem = TileWorkingSetSubsystem(tileRenderStore: context.tileRenderStore,
                                                              tileTraceRecorder: context.tileTraceRecorder,
                                                              terrainDemand: context.groundRelief?.store,
                                                              buildingsMinimumTileZoom: BuildingCoveragePlanner.minimumDrawZoom(settings: settings))
        let tileProjectionIndexSubsystem = TileProjectionIndexSubsystem(flatTileOriginCalculator: context.flatTileOriginCalculator)
        let baseLabelSubsystem = BaseLabelPrepareSubsystem(baseLabelCache: context.baseLabelCache,
                                                           roadLabelCache: context.roadLabelCache,
                                                           baseLabelTraceRecorder: context.baseLabelTraceRecorder,
                                                           metalDevice: context.metalContext.device,
                                                           settings: settings.labels,
                                                           debugOverlayControls: debugOverlayControls)
        let baseLabelDrawSubsystem = BaseLabelDrawSubsystem(textAtlas: textAtlas,
                                                            pipelines: labelPipelines,
                                                            poiSpriteAtlas: shared.get(PoiSpriteAtlas.self),
                                                            labelDepthState: depth.scene,
                                                            depthDisabledState: depth.disabled,
                                                            metalDevice: context.metalContext.device)
        let roadLabelDrawSubsystem = RoadLabelDrawSubsystem(textAtlas: textAtlas,
                                                            pipelines: labelPipelines,
                                                            labelDepthState: depth.scene,
                                                            depthDisabledState: depth.disabled,
                                                            fallbackDepthTexture: shared.get(RoadLabelSharedResources.self).sceneDepthFallbackTexture,
                                                            hidesBehindBuildingsFromZoom: settings.labels.road.hidesBehindBuildingsFromZoom,
                                                            metalDevice: context.metalContext.device)
        let pinSubsystem = PinRenderSubsystem(pinsRenderer: context.pinsRenderer,
                                                    pinSource: context.pinSource,
                                                    depthDisabledState: depth.disabled)
        let annotationSubsystem = AnnotationRenderSubsystem(annotationSource: context.annotationSource)
        let sceneModelSubsystem = SceneModelRenderSubsystem(sceneModelSource: context.sceneModelSource,
                                                            meshStore: context.sceneModelMeshStore,
                                                            pipeline: sceneModels.pipeline,
                                                            extrudedDepthState: depth.scene,
                                                            surfaceMaskState: sceneModels.surfaceMaskState,
                                                            groundCutStates: sceneModels.groundCutStates,
                                                            depthDisabledState: depth.disabled,
                                                            shadowMapTextureProvider: shadowMapTextureProvider,
                                                            shadowFallbackTexture: shadows.shadowFallbackTexture)
        let modelTileSubsystem = ModelTileRenderSubsystem(store: context.modelTileStore,
                                                          pipeline: shared.get(ModelTilePipeline.self),
                                                          extrudedDepthState: depth.scene,
                                                          surfaceMaskState: sceneModels.surfaceMaskState,
                                                          depthDisabledState: depth.disabled,
                                                          shadowMapTextureProvider: shadowMapTextureProvider,
                                                          shadowFallbackTexture: shadows.shadowFallbackTexture,
                                                          minimumZoom: settings.modelArchive.minimumZoom,
                                                          riseSeconds: settings.scene.extrusion.riseSeconds)
        let flatMapSurfaceSubsystem = FlatMapSurfaceRenderSubsystem(tilePipeline: shared.get(FlatGroundSharedResources.self).pipeline,
                                                                    groundOwnerState: tileDepth.groundOwner,
                                                                    tileStencilTestState: tileDepth.tileStencilTest,
                                                                    roadRankState: tileDepth.roadRank,
                                                                    depthDisabledState: depth.disabled,
                                                                    debugOverlayControls: debugOverlayControls,
                                                                    groundShadowMaskTextureProvider: groundShadowMaskTextureProvider,
                                                                    groundShadowMaskFallbackTexture: shadows.groundMaskFallbackTexture,
                                                                    shadowMapTextureProvider: shadowMapTextureProvider,
                                                                    shadowFallbackTexture: shadows.shadowFallbackTexture,
                                                                    groundFlatteningFromTileZoom: settings.tiles.resolvedGroundFlatteningFromTileZoom)
        let groundShadowMaskSubsystem = GroundShadowMaskRenderSubsystem(pipeline: shadows.groundMaskPipeline,
                                                                        depthDisabledState: depth.disabled,
                                                                        shadowMapTextureProvider: shadowMapTextureProvider)
        let placementStencilSubsystem = PlacementStencilRenderSubsystem(device: context.metalContext.device,
                                                                        pipeline: placement.pipeline,
                                                                        placementStencilWriteState: placement.stencilWrite,
                                                                        placementDepthWriteState: placement.depthWrite,
                                                                        placementStencilReliefWriteState: placement.stencilReliefWrite,
                                                                        placementDepthResetState: placement.depthReset,
                                                                        depthDisabledState: depth.disabled,
                                                                        groundFlattening: settings.tiles.groundFlattening)
        let rasterTileSubsystem = RasterTileRenderSubsystem(device: context.metalContext.device,
                                                            pipeline: shared.get(RasterTilePipeline.self),
                                                            settings: settings.tiles.rasterization,
                                                            groundOwnerState: tileDepth.groundOwner,
                                                            sphereOpaqueOwnerState: tileDepth.sphereOpaqueOwner,
                                                            depthDisabledState: depth.disabled,
                                                            debugOverlayControls: debugOverlayControls,
                                                            groundShadowMaskTextureProvider: groundShadowMaskTextureProvider,
                                                            groundShadowMaskFallbackTexture: shadows.groundMaskFallbackTexture,
                                                            shadowMapTextureProvider: shadowMapTextureProvider,
                                                            shadowFallbackTexture: shadows.shadowFallbackTexture,
                                                            groundFlattening: settings.tiles.groundFlattening)
        let buildingExtrusionSubsystem = BuildingExtrusionRenderSubsystem(extrudedTilePipeline: shared.get(ExtrudedTilePipeline.self),
                                                                          extrudedDepthState: depth.scene,
                                                                          extrudedStencilTestState: tileDepth.extrudedSurfaceMask,
                                                                          depthDisabledState: depth.disabled,
                                                                          shadowMapTextureProvider: shadowMapTextureProvider,
                                                                          shadowFallbackTexture: shadows.shadowFallbackTexture,
                                                                          extrusion: settings.scene.extrusion,
                                                                          debugOverlayControls: debugOverlayControls)
        let treeSubsystem = TreeRenderSubsystem(modelStore: context.treeModelStore,
                                                pipeline: shared.get(TreePipeline.self),
                                                palette: context.treePalette,
                                                stencilTestState: tileDepth.extrudedSurfaceMask,
                                                groundDepthState: depth.ground,
                                                depthDisabledState: depth.disabled,
                                                settings: settings.scene.trees,
                                                riseSeconds: settings.scene.extrusion.riseSeconds)
        let layerSubsystem = LayerRenderSubsystem(source: context.layerSource,
                                                  store: context.layerMeshStore,
                                                  pipeline: shared.get(LayerPipeline.self),
                                                  depthDisabledState: depth.disabled)
        let tileGridSubsystem = TileGridRenderSubsystem(source: context.tileGridSource,
                                                        pipeline: shared.get(TileGridPipeline.self),
                                                        textAtlas: textAtlas,
                                                        metalDevice: context.metalContext.device,
                                                        depthDisabledState: depth.disabled)
        let reliefShadowCasterSubsystem = GroundReliefShadowCasterSubsystem(device: context.metalContext.device,
                                                                            pipeline: shared.get(RasterTilePipeline.self),
                                                                            depthState: depth.scene,
                                                                            groundFlattening: settings.tiles.groundFlattening)
        let starfieldSubsystem = StarfieldRenderSubsystem(starfieldRenderer: context.starfieldRenderer,
                                                          skyBackdropDepthState: depth.sceneReadOnly,
                                                          depthDisabledState: depth.disabled)
        let horizonSubsystem = HorizonRenderSubsystem(horizonRenderer: context.horizonRenderer,
                                                      skyDepthState: depth.sceneReadOnly,
                                                      groundDepthState: horizon.groundDepthState,
                                                      depthDisabledState: depth.disabled)
        let postProcessingSubsystem = PostProcessingRenderSubsystem(fxaaPipeline: shared.get(FXAAPipeline.self),
                                                                    inputTextureProvider: postProcessingInputTextureProvider)
        let globeVectorSurfaceSubsystem = GlobeVectorSurfaceRenderSubsystem(pipeline: shared.get(GlobeVectorSurfaceSharedResources.self).pipeline,
                                                                            depthDisabledState: depth.disabled,
                                                                            opaqueDepthState: tileDepth.sphereOpaqueOwner,
                                                                            ribbonOwnerDepthState: tileDepth.sphereRibbonOwner,
                                                                            translucentDepthState: tileDepth.tileStencilTest,
                                                                            debugOverlayControls: debugOverlayControls)
        let surfaceLabelSubsystem = SurfaceLabelRenderSubsystem(pipeline: shared.get(SurfaceLabelPipeline.self),
                                                                textAtlas: textAtlas,
                                                                depthState: depth.ground,
                                                                depthDisabledState: depth.disabled)
        let globeCapSubsystem = GlobeCapRenderSubsystem(globeCapDepthState: depth.sceneReadOnly,
                                                        depthDisabledState: depth.disabled,
                                                        globeCapRenderer: context.globeCapRenderer)
        let debugSubsystem = DebugOverlayRenderSubsystem(polygonPipeline: shared.get(PolygonsPipeline.self),
                                                         debugOverlayRenderer: context.debugOverlayRenderer,
                                                         textAtlas: textAtlas,
                                                         controls: debugOverlayControls)

        // The model tiles follow the scene models, which start the
        // frame's model state over, and add to it.
        let subsystems: [any RenderSubsystem] = [
            tileWorkingSetSubsystem,
            tileProjectionIndexSubsystem,
            sceneModelSubsystem,
            modelTileSubsystem,
            // Before the labels: the buildings' rise this frame
            // (`BuildingFrameState.rise`) is the height
            // of the roofs the labels stand on.
            buildingExtrusionSubsystem,
            baseLabelSubsystem,
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            pinSubsystem,
            annotationSubsystem,
            groundShadowMaskSubsystem,
            // Before the ground of either surface: the planner's decision
            // in the stencil, the placements' marks
            // (`TileSourceStencilPriority`).
            placementStencilSubsystem,
            // The plane's vector ground, then its textures, each source
            // painting the ground its mark names, in whatever order.
            // Before the sphere's vector ground, as the sphere's rank
            // depth wants.
            flatMapSurfaceSubsystem,
            rasterTileSubsystem,
            // The trees draw in the buildings' layer, from the buildings'
            // coverage, and their shadow discs in the roads' layer after
            // the ground's subsystems have drawn the roads.
            treeSubsystem,
            // The mountains into the shadow map, beside the buildings.
            reliefShadowCasterSubsystem,
            starfieldSubsystem,
            globeVectorSurfaceSubsystem,
            // The layers of the app's data, in a layer of their own
            // (`RenderLayer.appLayers`).
            layerSubsystem,
            // The tile grid, in the overlay pass (`RenderLayer.tileGrid`).
            tileGridSubsystem,
            surfaceLabelSubsystem,
            globeCapSubsystem,
            horizonSubsystem,
            postProcessingSubsystem,
            debugSubsystem
        ]
        let availabilityProviders: [any RenderPassAvailabilityProvider] = [
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            pinSubsystem,
            sceneModelSubsystem,
            modelTileSubsystem,
            layerSubsystem,
            tileGridSubsystem,
            starfieldSubsystem,
            debugSubsystem
        ]
        return RenderGraph(registry: RenderSubsystemRegistry(subsystems: subsystems),
                           availabilityProviders: availabilityProviders)
    }
}
