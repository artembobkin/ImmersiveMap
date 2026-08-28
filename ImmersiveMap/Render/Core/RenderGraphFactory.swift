// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

enum RenderGraphFactory {
    static func makeDefaultGraph(context: RenderPersistentContext,
                                 settings: ImmersiveMapSettings,
                                 debugOverlayControls: DebugOverlayControlState,
                                 postProcessingInputTextureProvider: @escaping () -> MTLTexture?,
                                 buildingImageTextureProvider: @escaping () -> MTLTexture?,
                                 shadowMapTextureProvider: @escaping () -> MTLTexture?,
                                 groundShadowMaskTextureProvider: @escaping () -> MTLTexture?) -> RenderGraph {
        let tileDemandPlacementSubsystem = TileDemandPlacementSubsystem(tileRenderStore: context.tileRenderStore,
                                                                        tileTraceRecorder: context.tileTraceRecorder)
        let tileProjectionIndexSubsystem = TileProjectionIndexSubsystem(flatTileOriginCalculator: context.flatTileOriginCalculator)
        let tileGlobeTextureSubsystem = TileAtlasSubsystem(tilesTexture: context.tilesTexture,
                                                                  tileTraceRecorder: context.tileTraceRecorder)
        let baseLabelSubsystem = BaseLabelPrepareSubsystem(baseLabelCache: context.baseLabelCache,
                                                           roadLabelCache: context.roadLabelCache,
                                                           baseLabelTraceRecorder: context.baseLabelTraceRecorder,
                                                           metalDevice: context.metalContext.device,
                                                           screenComputePipelines: context.tilePointScreenPipelines,
                                                           roadPlacementPipeline: context.roadLabelPlacementPipeline,
                                                           settings: settings.labels,
                                                           debugOverlayControls: debugOverlayControls)
        let baseLabelDrawSubsystem = BaseLabelDrawSubsystem(textRenderer: context.textRenderer,
                                                            poiSpriteAtlas: context.poiSpriteAtlas,
                                                            labelDepthState: context.globeCapDepthState,
                                                            depthDisabledState: context.depthDisabledState,
                                                            metalDevice: context.metalContext.device)
        let roadLabelDrawSubsystem = RoadLabelDrawSubsystem(textRenderer: context.textRenderer,
                                                            labelDepthState: context.globeCapDepthState,
                                                            depthDisabledState: context.depthDisabledState,
                                                            metalDevice: context.metalContext.device)
        let avatarSubsystem = AvatarRenderSubsystem(avatarsRenderer: context.avatarsRenderer,
                                                    avatarSource: context.avatarSource,
                                                    depthDisabledState: context.depthDisabledState)
        let markerSubsystem = MarkerRenderSubsystem(markerSource: context.markerSource)
        let sceneModelSubsystem = SceneModelRenderSubsystem(sceneModelSource: context.sceneModelSource,
                                                            meshStore: context.sceneModelMeshStore,
                                                            pipeline: context.sceneModelPipeline,
                                                            extrudedDepthState: context.extrudedDepthState,
                                                            depthDisabledState: context.depthDisabledState,
                                                            shadowMapTextureProvider: shadowMapTextureProvider,
                                                            shadowFallbackTexture: context.shadowFallbackTexture,
                                                            supportsFramebufferFetch: context.supportsFramebufferFetch)
        let routeSubsystem = RouteRenderSubsystem(routeSource: context.routeSource,
                                                  pipeline: context.routePipeline,
                                                  routeDepthState: context.globeCapDepthState,
                                                  depthDisabledState: context.depthDisabledState,
                                                  metalDevice: context.metalContext.device)
        let flatMapSurfaceSubsystem = FlatMapSurfaceRenderSubsystem(tilePipeline: context.tilePipeline,
                                                                    groundDepthState: context.groundDepthState,
                                                                    depthDisabledState: context.depthDisabledState,
                                                                    separateRoadRenderingMinimumZoom: settings.style.flatSeparateRoadRenderingMinimumZoom,
                                                                    debugOverlayControls: debugOverlayControls,
                                                                    groundShadowMaskTextureProvider: groundShadowMaskTextureProvider,
                                                                    groundShadowMaskFallbackTexture: context.groundShadowMaskFallbackTexture,
                                                                    supportsFramebufferFetch: context.supportsFramebufferFetch)
        let groundShadowMaskSubsystem = GroundShadowMaskRenderSubsystem(pipeline: context.groundShadowMaskPipeline,
                                                                        depthDisabledState: context.depthDisabledState,
                                                                        shadowMapTextureProvider: shadowMapTextureProvider)
        let buildingExtrusionSubsystem = BuildingExtrusionRenderSubsystem(buildingImageTextureProvider: buildingImageTextureProvider,
                                                                          extrudedTilePipeline: context.extrudedTilePipeline,
                                                                          extrudedDepthState: context.extrudedDepthState,
                                                                          depthDisabledState: context.depthDisabledState,
                                                                          compositeDepthResetState: context.compositeDepthResetState,
                                                                          shadowMapTextureProvider: shadowMapTextureProvider,
                                                                          shadowFallbackTexture: context.shadowFallbackTexture,
                                                                          supportsFramebufferFetch: context.supportsFramebufferFetch)
        let starfieldSubsystem = StarfieldRenderSubsystem(starfieldRenderer: context.starfieldRenderer)
        let atmosphereSubsystem = AtmosphereRenderSubsystem(atmosphereRenderer: context.atmosphereRenderer,
                                                            depthDisabledState: context.depthDisabledState)
        let postProcessingSubsystem = PostProcessingRenderSubsystem(fxaaPipeline: context.fxaaPipeline,
                                                                    inputTextureProvider: postProcessingInputTextureProvider)
        let globeSurfaceSubsystem = GlobeSurfaceRenderSubsystem(globeDepthState: context.extrudedDepthState,
                                                                globePipeline: context.globePipeline,
                                                                placeholderPipeline: context.globeSurfacePlaceholderPipeline,
                                                                mapSurfaceGridBuffers: context.mapSurfaceGridBuffers,
                                                                tilesTexture: context.tilesTexture,
                                                                debugOverlayControls: debugOverlayControls)
        let globeCapSubsystem = GlobeCapRenderSubsystem(globeCapDepthState: context.globeCapDepthState,
                                                        depthDisabledState: context.depthDisabledState,
                                                        globeCapRenderer: context.globeCapRenderer,
                                                        tilesTexture: context.tilesTexture)
        let debugSubsystem = DebugOverlayRenderSubsystem(polygonPipeline: context.polygonPipeline,
                                                         debugOverlayRenderer: context.debugOverlayRenderer,
                                                         textRenderer: context.textRenderer,
                                                         controls: debugOverlayControls)

        let subsystems: [any RenderSubsystem] = [
            tileDemandPlacementSubsystem,
            tileProjectionIndexSubsystem,
            tileGlobeTextureSubsystem,
            baseLabelSubsystem,
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            avatarSubsystem,
            markerSubsystem,
            sceneModelSubsystem,
            routeSubsystem,
            groundShadowMaskSubsystem,
            flatMapSurfaceSubsystem,
            buildingExtrusionSubsystem,
            starfieldSubsystem,
            atmosphereSubsystem,
            globeSurfaceSubsystem,
            globeCapSubsystem,
            postProcessingSubsystem,
            debugSubsystem
        ]
        let availabilityProviders: [any RenderPassAvailabilityProvider] = [
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            avatarSubsystem,
            sceneModelSubsystem,
            starfieldSubsystem,
            atmosphereSubsystem,
            debugSubsystem
        ]
        return RenderGraph(registry: RenderSubsystemRegistry(subsystems: subsystems),
                           availabilityProviders: availabilityProviders)
    }
}
