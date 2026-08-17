// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum GlobeSurfaceDrawer {
    /// Blank tiles in the map's background color for every visible slot that
    /// no content paints yet, drawn before the atlas mappings. A tile that has
    /// not arrived (or a hole in coverage) then reads as blank map rather than
    /// as a window into space, and the depth it writes is the depth the tile
    /// will write.
    ///
    /// Each fill draws the exact slot the missing tile targets, on the same
    /// grid, so the arriving tile lands on identical geometry and depth. A
    /// single coarser fill (the whole sphere was tried) touches the true
    /// sphere at its own grid vertices while the finer tile mesh chords under
    /// it there, and every such vertex showed as a background-colored dot.
    ///
    /// The atlas fields of `TileData` go unread because the fragment stage
    /// never samples a texture.
    static func drawPlaceholderTiles(renderEncoder: MTLRenderCommandEncoder,
                                     cameraUniform: CameraUniform,
                                     globe: GlobeUniform,
                                     earthScene: EarthSceneUniform,
                                     placeholderPipeline: GlobePipeline,
                                     mapSurfaceGridBuffers: MapSurfaceGridBuffers,
                                     horizonFog: HorizonFogUniform,
                                     atmosphere: GlobeAtmosphereUniform,
                                     fillColor: SIMD4<Float>,
                                     slots: [Tile]) {
        guard slots.isEmpty == false else {
            return
        }
        var cameraUniformValue = cameraUniform
        var earthSceneValue = earthScene
        var globeValue = globe
        var horizonFogValue = horizonFog
        var atmosphereValue = atmosphere
        var fillColorValue = fillColor

        placeholderPipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.front)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&earthSceneValue, length: MemoryLayout<EarthSceneUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&horizonFogValue,
                                       length: MemoryLayout<HorizonFogUniform>.stride,
                                       index: 4)
        renderEncoder.setFragmentBytes(&fillColorValue,
                                       length: MemoryLayout<SIMD4<Float>>.stride,
                                       index: 5)
        renderEncoder.setFragmentBytes(&atmosphereValue,
                                       length: MemoryLayout<GlobeAtmosphereUniform>.stride,
                                       index: 6)
        renderEncoder.setVertexBuffer(mapSurfaceGridBuffers.verticesBuffer, offset: 0, index: 0)
        for slot in slots {
            let slotVector = simd_int3(Int32(slot.x), Int32(slot.y), Int32(slot.z))
            var slotData = TileAtlasTexture.TileData(position: 0,
                                                     textureSize: 1,
                                                     cellSize: 1,
                                                     tile: slotVector,
                                                     sourceTile: slotVector)
            renderEncoder.setVertexBytes(&slotData,
                                         length: MemoryLayout<TileAtlasTexture.TileData>.stride,
                                         index: 3)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: mapSurfaceGridBuffers.indicesCount,
                                                indexType: mapSurfaceGridBuffers.indexType,
                                                indexBuffer: mapSurfaceGridBuffers.indicesBuffer,
                                                indexBufferOffset: 0)
        }
    }

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     globe: GlobeUniform,
                     earthScene: EarthSceneUniform,
                     globePipeline: GlobePipeline,
                     mapSurfaceGridBuffers: MapSurfaceGridBuffers,
                     tilesTexture: TileAtlasTexture,
                     horizonFog: HorizonFogUniform,
                     atmosphere: GlobeAtmosphereUniform,
                     isWireframeEnabled: Bool) {
        var cameraUniformValue = cameraUniform
        var earthSceneValue = earthScene
        var globeValue = globe
        var atmosphereValue = atmosphere

        globePipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.front)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }
        var horizonFogValue = horizonFog
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&earthSceneValue, length: MemoryLayout<EarthSceneUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&horizonFogValue,
                                       length: MemoryLayout<HorizonFogUniform>.stride,
                                       index: 4)
        renderEncoder.setFragmentBytes(&atmosphereValue,
                                       length: MemoryLayout<GlobeAtmosphereUniform>.stride,
                                       index: 6)
        renderEncoder.setVertexBuffer(mapSurfaceGridBuffers.verticesBuffer, offset: 0, index: 0)

        let pageMappings = TileAtlasPageMappingSorter.sortedPageMappings(tilesTexture: tilesTexture)
        var activePageIndex: Int?
        for pageMapping in pageMappings {
            if activePageIndex != pageMapping.pageIndex {
                renderEncoder.setFragmentTexture(tilesTexture.pages[pageMapping.pageIndex].texture, index: 0)
                activePageIndex = pageMapping.pageIndex
            }
            let mapping = pageMapping.mapping
            var mappingValue = mapping
            renderEncoder.setVertexBytes(&mappingValue,
                                         length: MemoryLayout<TileAtlasTexture.TileData>.stride,
                                         index: 3)
            renderEncoder.setFragmentBytes(&mappingValue,
                                           length: MemoryLayout<TileAtlasTexture.TileData>.stride,
                                           index: 3)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: mapSurfaceGridBuffers.indicesCount,
                                                indexType: mapSurfaceGridBuffers.indexType,
                                                indexBuffer: mapSurfaceGridBuffers.indicesBuffer,
                                                indexBufferOffset: 0)
        }
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
    }
}
