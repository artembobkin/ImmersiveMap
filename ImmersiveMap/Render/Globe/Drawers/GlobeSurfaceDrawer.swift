// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

enum GlobeSurfaceDrawer {
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     globe: GlobeUniform,
                     earthScene: EarthSceneUniform,
                     nightLightsAtlasState: NightLightsAtlasState,
                     globePipeline: GlobePipeline,
                     mapSurfaceGridBuffers: MapSurfaceGridBuffers,
                     tilesTexture: GlobeTilesTexture,
                     isWireframeEnabled: Bool) {
        var cameraUniformValue = cameraUniform
        var earthSceneValue = earthScene
        var globeValue = globe
        let nightLightsAtlasBinding = NightLightsAtlasSurfaceBinding(state: nightLightsAtlasState)
        var nightLightsAtlasCounts = SIMD2<UInt32>(UInt32(nightLightsAtlasBinding.entryUniforms.count),
                                                   UInt32(nightLightsAtlasBinding.pages.count))
        var emptyNightLightsAtlasEntry = NightLightsAtlasEntryUniform(tile: SIMD3<Int32>(0, 0, 0),
                                                                      pageIndex: 0,
                                                                      uvOrigin: SIMD2<Float>(0, 0),
                                                                      uvScale: SIMD2<Float>(0, 0))

        globePipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setCullMode(.front)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&earthSceneValue, length: MemoryLayout<EarthSceneUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&nightLightsAtlasCounts,
                                       length: MemoryLayout<SIMD2<UInt32>>.stride,
                                       index: 4)
        if nightLightsAtlasBinding.entryUniforms.isEmpty {
            renderEncoder.setFragmentBytes(&emptyNightLightsAtlasEntry,
                                           length: MemoryLayout<NightLightsAtlasEntryUniform>.stride,
                                           index: 5)
        } else {
            nightLightsAtlasBinding.entryUniforms.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return
                }
                renderEncoder.setFragmentBytes(baseAddress,
                                               length: rawBuffer.count,
                                               index: 5)
            }
        }
        renderEncoder.setVertexBuffer(mapSurfaceGridBuffers.verticesBuffer, offset: 0, index: 0)

        let pageMappings = GlobeTilePageMappingSorter.sortedPageMappings(tilesTexture: tilesTexture)
        var activePageIndex: Int?
        for pageMapping in pageMappings {
            if activePageIndex != pageMapping.pageIndex {
                let mapTexture = tilesTexture.pages[pageMapping.pageIndex].texture
                renderEncoder.setFragmentTexture(mapTexture, index: 0)
                for pageIndex in 0..<NightLightsAtlasSurfaceBinding.maxPageCount {
                    let atlasTexture = pageIndex < nightLightsAtlasBinding.pages.count
                        ? nightLightsAtlasBinding.pages[pageIndex]
                        : mapTexture
                    renderEncoder.setFragmentTexture(atlasTexture, index: 1 + pageIndex)
                }
                activePageIndex = pageMapping.pageIndex
            }
            let mapping = pageMapping.mapping
            var mappingValue = mapping
            renderEncoder.setVertexBytes(&mappingValue,
                                         length: MemoryLayout<GlobeTilesTexture.TileData>.stride,
                                         index: 3)
            renderEncoder.setFragmentBytes(&mappingValue,
                                           length: MemoryLayout<GlobeTilesTexture.TileData>.stride,
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
