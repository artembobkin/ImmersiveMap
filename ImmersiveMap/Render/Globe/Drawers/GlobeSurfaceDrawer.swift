// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum GlobeSurfaceDrawer {
    /// The whole sphere in one draw, in the map's background color, before any
    /// tile. A tile that has not arrived (or a hole in coverage) then reads as
    /// blank map rather than as a window into space, and the depth it writes is
    /// the same depth a tile would have written there.
    ///
    /// `tile.z = 0` makes the grid span the entire Mercator range in a single
    /// draw; the atlas fields go unread because the fragment stage never
    /// samples a texture.
    static func drawPlaceholder(renderEncoder: MTLRenderCommandEncoder,
                                cameraUniform: CameraUniform,
                                globe: GlobeUniform,
                                earthScene: EarthSceneUniform,
                                placeholderPipeline: GlobePipeline,
                                mapSurfaceGridBuffers: MapSurfaceGridBuffers,
                                horizonFog: HorizonFogUniform,
                                fillColor: SIMD4<Float>) {
        var cameraUniformValue = cameraUniform
        var earthSceneValue = earthScene
        var globeValue = globe
        var horizonFogValue = horizonFog
        var fillColorValue = fillColor
        var wholeSphere = TileAtlasTexture.TileData(position: 0,
                                                    textureSize: 1,
                                                    cellSize: 1,
                                                    tile: simd_int3(0, 0, 0),
                                                    sourceTile: simd_int3(0, 0, 0))

        placeholderPipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.front)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setVertexBytes(&wholeSphere,
                                     length: MemoryLayout<TileAtlasTexture.TileData>.stride,
                                     index: 3)
        renderEncoder.setFragmentBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&earthSceneValue, length: MemoryLayout<EarthSceneUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&horizonFogValue,
                                       length: MemoryLayout<HorizonFogUniform>.stride,
                                       index: 4)
        renderEncoder.setFragmentBytes(&fillColorValue,
                                       length: MemoryLayout<SIMD4<Float>>.stride,
                                       index: 5)
        renderEncoder.setVertexBuffer(mapSurfaceGridBuffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: mapSurfaceGridBuffers.indicesCount,
                                            indexType: .uint32,
                                            indexBuffer: mapSurfaceGridBuffers.indicesBuffer,
                                            indexBufferOffset: 0)
    }

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     globe: GlobeUniform,
                     earthScene: EarthSceneUniform,
                     globePipeline: GlobePipeline,
                     mapSurfaceGridBuffers: MapSurfaceGridBuffers,
                     tilesTexture: TileAtlasTexture,
                     horizonFog: HorizonFogUniform,
                     isWireframeEnabled: Bool) {
        var cameraUniformValue = cameraUniform
        var earthSceneValue = earthScene
        var globeValue = globe

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
                                                indexType: .uint32,
                                                indexBuffer: mapSurfaceGridBuffers.indicesBuffer,
                                                indexBufferOffset: 0)
        }
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
    }
}
