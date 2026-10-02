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
                                                              tileTraceRecorder: context.tileTraceRecorder)
        let tileProjectionIndexSubsystem = TileProjectionIndexSubsystem(flatTileOriginCalculator: context.flatTileOriginCalculator)
        let baseLabelSubsystem = BaseLabelPrepareSubsystem(baseLabelCache: context.baseLabelCache,
                                                           roadLabelCache: context.roadLabelCache,
                                                           baseLabelTraceRecorder: context.baseLabelTraceRecorder,
                                                           metalDevice: context.metalContext.device,
                                                           occlusionProbePipeline: context.labelOcclusionProbePipeline,
                                                           depthDisabledState: context.depthDisabledState,
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
                                                            fallbackDepthTexture: context.shadowFallbackTexture,
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
                                                          shadowFallbackTexture: context.shadowFallbackTexture)
        let flatMapSurfaceSubsystem = FlatMapSurfaceRenderSubsystem(tilePipeline: context.tilePipeline,
                                                                    groundOwnerState: context.groundOwnerState,
                                                                    tileStencilTestState: context.tileStencilTestState,
                                                                    roadRankState: context.roadRankState,
                                                                    depthDisabledState: context.depthDisabledState,
                                                                    debugOverlayControls: debugOverlayControls,
                                                                    groundShadowMaskTextureProvider: groundShadowMaskTextureProvider,
                                                                    groundShadowMaskFallbackTexture: context.groundShadowMaskFallbackTexture)
        let groundShadowMaskSubsystem = GroundShadowMaskRenderSubsystem(pipeline: context.groundShadowMaskPipeline,
                                                                        depthDisabledState: context.depthDisabledState,
                                                                        shadowMapTextureProvider: shadowMapTextureProvider)
        let tileOwnershipSubsystem = TileOwnershipRenderSubsystem(pipeline: context.tileOwnershipPipeline,
                                                                  tileOwnershipWriteState: context.tileOwnershipWriteState,
                                                                  depthDisabledState: context.depthDisabledState)
        let buildingExtrusionSubsystem = BuildingExtrusionRenderSubsystem(extrudedTilePipeline: context.extrudedTilePipeline,
                                                                          extrudedDepthState: context.extrudedDepthState,
                                                                          extrudedStencilTestState: context.extrudedStencilTestState,
                                                                          depthDisabledState: context.depthDisabledState,
                                                                          shadowMapTextureProvider: shadowMapTextureProvider,
                                                                          shadowFallbackTexture: context.shadowFallbackTexture,
                                                                          debugOverlayControls: debugOverlayControls)
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
            baseLabelSubsystem,
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            avatarSubsystem,
            markerSubsystem,
            groundShadowMaskSubsystem,
            tileOwnershipSubsystem,
            flatMapSurfaceSubsystem,
            buildingExtrusionSubsystem,
            starfieldSubsystem,
            globeVectorSurfaceSubsystem,
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
