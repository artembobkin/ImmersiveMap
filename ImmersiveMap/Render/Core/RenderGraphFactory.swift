// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

enum RenderGraphFactory {
    static func makeDefaultGraph(context: RenderPersistentContext,
                                 settings: ImmersiveMapSettings,
                                 debugOverlayControls: DebugOverlayControlState,
                                 postProcessingInputTextureProvider: @escaping () -> MTLTexture?,
                                 buildingWinnerIDTextureProvider: @escaping () -> MTLTexture?) -> RenderGraph {
        let tileDemandPlacementSubsystem = TileDemandPlacementSubsystem(tileRenderStore: context.tileRenderStore,
                                                                        tileTraceRecorder: context.tileTraceRecorder)
        let tileProjectionIndexSubsystem = TileProjectionIndexSubsystem(flatTileOriginCalculator: context.flatTileOriginCalculator)
        let tileGlobeTextureSubsystem = TileGlobeTextureSubsystem(tilesTexture: context.tilesTexture,
                                                                  tileTraceRecorder: context.tileTraceRecorder)
        let nightLightsGlobeTextureSubsystem = NightLightsGlobeTextureSubsystem(tileSetStore: context.nightLightsTileSetStore,
                                                                                tileCache: context.nightLightsTileCache,
                                                                                atlasTexture: context.nightLightsAtlasTexture)
        let baseLabelSubsystem = BaseLabelPrepareSubsystem(baseLabelCache: context.baseLabelCache,
                                                           roadLabelCache: context.roadLabelCache,
                                                           baseLabelTraceRecorder: context.baseLabelTraceRecorder,
                                                           metalDevice: context.metalContext.device,
                                                           library: context.metalContext.library,
                                                           settings: settings.labels)
        let baseLabelDrawSubsystem = BaseLabelDrawSubsystem(textRenderer: context.textRenderer,
                                                            poiSpriteAtlas: context.poiSpriteAtlas,
                                                            metalDevice: context.metalContext.device)
        let roadLabelDrawSubsystem = RoadLabelDrawSubsystem(textRenderer: context.textRenderer,
                                                            metalDevice: context.metalContext.device)
        let avatarSubsystem = AvatarRenderSubsystem(avatarsRenderer: context.avatarsRenderer,
                                                    avatarSource: context.avatarSource,
                                                    depthDisabledState: context.depthDisabledState)
        let buildingWinnerSubsystem = BuildingWinnerRenderSubsystem(extrudedTilePipeline: context.extrudedTilePipeline,
                                                                    extrudedDepthState: context.extrudedDepthState)
        let flatMapSurfaceSubsystem = FlatMapSurfaceRenderSubsystem(tilePipeline: context.tilePipeline,
                                                                    separateRoadRenderingMinimumZoom: settings.style.flatSeparateRoadRenderingMinimumZoom,
                                                                    debugOverlayControls: debugOverlayControls)
        let buildingExtrusionSubsystem = BuildingExtrusionRenderSubsystem(buildingExtrusionAlpha: settings.style.buildingExtrusionAlpha,
                                                                          buildingWinnerIDTextureProvider: buildingWinnerIDTextureProvider,
                                                                          extrudedTilePipeline: context.extrudedTilePipeline,
                                                                          extrudedColorPassDepthState: context.extrudedColorPassDepthState,
                                                                          depthDisabledState: context.depthDisabledState)
        let starfieldSubsystem = StarfieldRenderSubsystem(starfieldRenderer: context.starfieldRenderer)
        let postProcessingSubsystem = PostProcessingRenderSubsystem(fxaaPipeline: context.fxaaPipeline,
                                                                    inputTextureProvider: postProcessingInputTextureProvider)
        let globeSurfaceSubsystem = GlobeSurfaceRenderSubsystem(globeDepthState: context.extrudedDepthState,
                                                                globePipeline: context.globePipeline,
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
            nightLightsGlobeTextureSubsystem,
            baseLabelSubsystem,
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            avatarSubsystem,
            buildingWinnerSubsystem,
            flatMapSurfaceSubsystem,
            buildingExtrusionSubsystem,
            starfieldSubsystem,
            globeSurfaceSubsystem,
            globeCapSubsystem,
            postProcessingSubsystem,
            debugSubsystem
        ]
        let availabilityProviders: [any RenderPassAvailabilityProvider] = [
            baseLabelDrawSubsystem,
            roadLabelDrawSubsystem,
            avatarSubsystem,
            debugSubsystem
        ]
        return RenderGraph(registry: RenderSubsystemRegistry(subsystems: subsystems),
                           availabilityProviders: availabilityProviders)
    }
}
