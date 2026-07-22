// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

enum GlobeSurfaceDrawer {
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
