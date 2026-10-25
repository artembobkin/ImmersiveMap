// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

enum RenderGraphFactory {
    static func makeDefaultGraph(context: RenderPersistentContext,
                                 settings: ImmersiveMapSettings,
                                 debugOverlayControls: DebugOverlayControlState,
                                 postProcessingInputTextureProvider: @escaping () -> MTLTexture?,
                                 shadowMapTextureProvider: @escaping () -> MTLTexture?,
                                 groundShadowMaskTextureProvider: @escaping () -> MTLTexture?) -> RenderGraph {
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
        let baseLabelDrawSubsystem = BaseLabelDrawSubsystem(textRenderer: context.textRenderer,
                                                            poiSpriteAtlas: context.poiSpriteAtlas,
                                                            labelDepthState: context.labelDepthState,
                                                            depthDisabledState: context.depthDisabledState,
                                                            metalDevice: context.metalContext.device)
        let roadLabelDrawSubsystem = RoadLabelDrawSubsystem(textRenderer: context.textRenderer,
                                                            labelDepthState: context.labelDepthState,
                                                            depthDisabledState: context.depthDisabledState,
                                                            fallbackDepthTexture: context.sceneDepthFallbackTexture,
                                                            hidesBehindBuildingsFromZoom: settings.labels.road.hidesBehindBuildingsFromZoom,
                                                            metalDevice: context.metalContext.device)
        let avatarSubsystem = AvatarRenderSubsystem(avatarsRenderer: context.avatarsRenderer,
                                                    avatarSource: context.avatarSource,
                                                    depthDisabledState: context.depthDisabledState)
        let markerSubsystem = MarkerRenderSubsystem(markerSource: context.markerSource)
        let sceneModelSubsystem = SceneModelRenderSubsystem(sceneModelSource: context.sceneModelSource,
                                                            meshStore: context.sceneModelMeshStore,
                                                            pipeline: context.sceneModelPipeline,
                                                            extrudedDepthState: context.extrudedDepthState,
                                                            surfaceMaskState: context.sceneModelSurfaceMaskState,
                                                            groundCutStates: context.sceneModelGroundCutStates,
                                                            depthDisabledState: context.depthDisabledState,
                                                            shadowMapTextureProvider: shadowMapTextureProvider,
                                                            shadowFallbackTexture: context.shadowFallbackTexture)
        let modelTileSubsystem = ModelTileRenderSubsystem(store: context.modelTileStore,
                                                          pipeline: context.modelTilePipeline,
                                                          extrudedDepthState: context.extrudedDepthState,
                                                          surfaceMaskState: context.sceneModelSurfaceMaskState,
                                                          groundCutStates: context.sceneModelGroundCutStates,
                                                          depthDisabledState: context.depthDisabledState,
                                                          shadowMapTextureProvider: shadowMapTextureProvider,
                                                          shadowFallbackTexture: context.shadowFallbackTexture,
                                                          minimumZoom: settings.modelArchive?.minimumZoom ?? 0,
                                                          riseSeconds: settings.scene.extrusion.riseSeconds)
        let flatMapSurfaceSubsystem = FlatMapSurfaceRenderSubsystem(tilePipeline: context.tilePipeline,
                                                                    groundOwnerState: context.groundOwnerState,
                                                                    tileStencilTestState: context.tileStencilTestState,
                                                                    roadRankState: context.roadRankState,
                                                                    depthDisabledState: context.depthDisabledState,
                                                                    debugOverlayControls: debugOverlayControls,
                                                                    groundShadowMaskTextureProvider: groundShadowMaskTextureProvider,
                                                                    groundShadowMaskFallbackTexture: context.groundShadowMaskFallbackTexture,
                                                                    shadowMapTextureProvider: shadowMapTextureProvider,
                                                                    shadowFallbackTexture: context.shadowFallbackTexture,
                                                                    groundFlatteningFromTileZoom: settings.tiles.resolvedGroundFlatteningFromTileZoom)
        let groundShadowMaskSubsystem = GroundShadowMaskRenderSubsystem(pipeline: context.groundShadowMaskPipeline,
                                                                        depthDisabledState: context.depthDisabledState,
                                                                        shadowMapTextureProvider: shadowMapTextureProvider)
        let placementStencilSubsystem = PlacementStencilRenderSubsystem(device: context.metalContext.device,
                                                                        pipeline: context.placementStencilPipeline,
                                                                        placementStencilWriteState: context.placementStencilWriteState,
                                                                        placementDepthWriteState: context.placementDepthWriteState,
                                                                        placementStencilReliefWriteState: context.placementStencilReliefWriteState,
                                                                        placementDepthResetState: context.placementDepthResetState,
                                                                        depthDisabledState: context.depthDisabledState,
                                                                        groundFlattening: settings.tiles.groundFlattening)
        let rasterTileSubsystem = RasterTileRenderSubsystem(device: context.metalContext.device,
                                                            pipeline: context.rasterTilePipeline,
                                                            settings: settings.tiles.rasterization,
                                                            groundOwnerState: context.groundOwnerState,
                                                            sphereOpaqueOwnerState: context.sphereOpaqueOwnerState,
                                                            depthDisabledState: context.depthDisabledState,
                                                            debugOverlayControls: debugOverlayControls,
                                                            groundShadowMaskTextureProvider: groundShadowMaskTextureProvider,
                                                            groundShadowMaskFallbackTexture: context.groundShadowMaskFallbackTexture,
                                                            shadowMapTextureProvider: shadowMapTextureProvider,
                                                            shadowFallbackTexture: context.shadowFallbackTexture,
                                                            groundFlattening: settings.tiles.groundFlattening)
        let buildingExtrusionSubsystem = BuildingExtrusionRenderSubsystem(extrudedTilePipeline: context.extrudedTilePipeline,
                                                                          extrudedDepthState: context.extrudedDepthState,
                                                                          extrudedStencilTestState: context.extrudedStencilTestState,
                                                                          depthDisabledState: context.depthDisabledState,
                                                                          shadowMapTextureProvider: shadowMapTextureProvider,
                                                                          shadowFallbackTexture: context.shadowFallbackTexture,
                                                                          extrusion: settings.scene.extrusion,
                                                                          debugOverlayControls: debugOverlayControls)
        let treeSubsystem = TreeRenderSubsystem(modelStore: context.treeModelStore,
                                                pipeline: context.treePipeline,
                                                palette: context.treePalette,
                                                stencilTestState: context.extrudedStencilTestState,
                                                groundDepthState: context.groundDepthState,
                                                depthDisabledState: context.depthDisabledState,
                                                settings: settings.scene.trees,
                                                riseSeconds: settings.scene.extrusion.riseSeconds)
        let layerSubsystem = LayerRenderSubsystem(store: context.layerMeshStore,
                                                  pipeline: context.layerPipeline,
                                                  depthDisabledState: context.depthDisabledState)
        let reliefShadowCasterSubsystem = GroundReliefShadowCasterSubsystem(device: context.metalContext.device,
                                                                            pipeline: context.rasterTilePipeline,
                                                                            depthState: context.extrudedDepthState,
                                                                            groundFlattening: settings.tiles.groundFlattening)
        let starfieldSubsystem = StarfieldRenderSubsystem(starfieldRenderer: context.starfieldRenderer,
                                                          skyBackdropDepthState: context.skyBackdropDepthState,
                                                          depthDisabledState: context.depthDisabledState)
        let horizonSubsystem = HorizonRenderSubsystem(horizonRenderer: context.horizonRenderer,
                                                      skyDepthState: context.skyBackdropDepthState,
                                                      groundDepthState: context.horizonGroundDepthState,
                                                      depthDisabledState: context.depthDisabledState)
        let postProcessingSubsystem = PostProcessingRenderSubsystem(fxaaPipeline: context.fxaaPipeline,
                                                                    inputTextureProvider: postProcessingInputTextureProvider)
        let globeVectorSurfaceSubsystem = GlobeVectorSurfaceRenderSubsystem(pipeline: context.globeVectorSurfacePipeline,
                                                                            depthDisabledState: context.depthDisabledState,
                                                                            opaqueDepthState: context.sphereOpaqueOwnerState,
                                                                            ribbonOwnerDepthState: context.sphereRibbonOwnerState,
                                                                            translucentDepthState: context.tileStencilTestState,
                                                                            debugOverlayControls: debugOverlayControls)
        let surfaceLabelSubsystem = SurfaceLabelRenderSubsystem(pipeline: context.surfaceLabelPipeline,
                                                                textRenderer: context.textRenderer,
                                                                depthState: context.groundDepthState,
                                                                depthDisabledState: context.depthDisabledState)
        let globeCapSubsystem = GlobeCapRenderSubsystem(globeCapDepthState: context.globeCapDepthState,
                                                        depthDisabledState: context.depthDisabledState,
                                                        globeCapRenderer: context.globeCapRenderer)
        let debugSubsystem = DebugOverlayRenderSubsystem(polygonPipeline: context.polygonPipeline,
                                                         debugOverlayRenderer: context.debugOverlayRenderer,
                                                         textRenderer: context.textRenderer,
                                                         controls: debugOverlayControls)

        // The model tiles follow the scene models, which start the
        // frame's model state over, and add to it.
        let subsystems: [any RenderSubsystem] = [
            tileWorkingSetSubsystem,
            tileProjectionIndexSubsystem,
            sceneModelSubsystem,
            modelTileSubsystem,
            // Before the labels: the buildings' rise this frame
            // (`FrameContextSharedState.buildingHeightScale`) is the height
            // of the roofs the labels stand on.
            buildingExtrusionSubsystem,
            baseLabelSubsystem,
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            avatarSubsystem,
            markerSubsystem,
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
            // The layers of the app's data over the ground of either
            // surface: after the flat map's roads and the trees' shadows,
            // after the globe's ground, before the labels painted on both.
            layerSubsystem,
            surfaceLabelSubsystem,
            globeCapSubsystem,
            horizonSubsystem,
            postProcessingSubsystem,
            debugSubsystem
        ]
        let availabilityProviders: [any RenderPassAvailabilityProvider] = [
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            avatarSubsystem,
            sceneModelSubsystem,
            modelTileSubsystem,
            starfieldSubsystem,
            debugSubsystem
        ]
        return RenderGraph(registry: RenderSubsystemRegistry(subsystems: subsystems),
                           availabilityProviders: availabilityProviders)
    }
}
