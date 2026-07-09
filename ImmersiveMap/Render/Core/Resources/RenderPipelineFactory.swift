// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderPipelineFactory.swift
//  ImmersiveMap
//

import Metal
import QuartzCore

struct RenderPipelineBundle {
    let polygonPipeline: PolygonsPipeline
    let tilePipeline: TilePipeline
    let globeTileTexturePipeline: TilePipeline
    let extrudedTilePipeline: ExtrudedTilePipeline
    let globePipeline: GlobePipeline
    let terrainPipeline: TerrainPipeline
    let fxaaPipeline: FXAAPipeline
    let starfieldRenderer: StarfieldRenderer
}

final class RenderPipelineFactory {
    private let metalContext: RenderMetalContext
    private let layer: CAMetalLayer
    private let config: ImmersiveMapSettings

    init(metalContext: RenderMetalContext,
         layer: CAMetalLayer,
         config: ImmersiveMapSettings) {
        self.metalContext = metalContext
        self.layer = layer
        self.config = config
    }

    func makeRenderPipelines() -> RenderPipelineBundle {
        let metalDevice = metalContext.device
        let library = metalContext.library
        let sampleCount = metalContext.renderSampleCount
        let polygonPipeline = PolygonsPipeline(metalDevice: metalDevice,
                                               layer: layer,
                                               library: library)
        let tilePipeline = TilePipeline(metalDevice: metalDevice,
                                        layer: layer,
                                        library: library,
                                        sampleCount: sampleCount)
        let globeTileTexturePipeline = TilePipeline(metalDevice: metalDevice,
                                                    layer: layer,
                                                    library: library)
        let extrudedTilePipeline = ExtrudedTilePipeline(metalDevice: metalDevice,
                                                        layer: layer,
                                                        library: library,
                                                        sampleCount: sampleCount)
        let globePipeline = GlobePipeline(metalDevice: metalDevice,
                                          layer: layer,
                                          library: library,
                                          sampleCount: sampleCount)
        let terrainPipeline = TerrainPipeline(metalDevice: metalDevice,
                                              layer: layer,
                                              library: library,
                                              sampleCount: sampleCount)
        let fxaaPipeline = FXAAPipeline(metalDevice: metalDevice,
                                        layer: layer,
                                        library: library)
        let starfieldRenderer = StarfieldRenderer(metalDevice: metalDevice,
                                                  layer: layer,
                                                  library: library,
                                                  sampleCount: sampleCount,
                                                  spaceColor: config.scene.space.clearColor,
                                                  transitionTargetColor: config.scene.mapClearColor,
                                                  config: config.scene.starfield)

        return RenderPipelineBundle(polygonPipeline: polygonPipeline,
                                    tilePipeline: tilePipeline,
                                    globeTileTexturePipeline: globeTileTexturePipeline,
                                    extrudedTilePipeline: extrudedTilePipeline,
                                    globePipeline: globePipeline,
                                    terrainPipeline: terrainPipeline,
                                    fxaaPipeline: fxaaPipeline,
                                    starfieldRenderer: starfieldRenderer)
    }
}
