// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum GlobeSurfaceDrawer {
    /// Blank tiles in the map's background color for every target slot of the
    /// globe surface, drawn before the tile geometry. A tile that has not
    /// arrived (or a hole in coverage) then reads as blank map rather than as
    /// a window into space, and the depth the fill writes is the surface depth
    /// everything else (the tile geometry, routes, scene models, the label
    /// occlusion prepass) tests against.
    ///
    /// Each fill draws the exact slot on the same grid as its neighbours. A
    /// single coarser fill (the whole sphere was tried) touches the true
    /// sphere at its own grid vertices while finer geometry chords under it
    /// there, and every such vertex showed as a background-colored dot.
    static func drawPlaceholderTiles(renderEncoder: MTLRenderCommandEncoder,
                                     cameraUniform: CameraUniform,
                                     globe: GlobeUniform,
                                     earthScene: EarthSceneUniform,
                                     placeholderPipeline: GlobePipeline,
                                     mapSurfaceGridBuffers: MapSurfaceGridBuffers,
                                     horizonFog: HorizonFogUniform,
                                     atmosphere: GlobeAtmosphereUniform,
                                     tone: GlobeSurfaceToneUniform,
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
        var toneValue = tone
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
        renderEncoder.setFragmentBytes(&toneValue,
                                       length: MemoryLayout<GlobeSurfaceToneUniform>.stride,
                                       index: 7)
        renderEncoder.setVertexBuffer(mapSurfaceGridBuffers.verticesBuffer, offset: 0, index: 0)
        for slot in slots {
            var slotData = GlobeSurfaceSlotUniform(slot)
            renderEncoder.setVertexBytes(&slotData,
                                         length: MemoryLayout<GlobeSurfaceSlotUniform>.stride,
                                         index: 3)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: mapSurfaceGridBuffers.indicesCount,
                                                indexType: mapSurfaceGridBuffers.indexType,
                                                indexBuffer: mapSurfaceGridBuffers.indicesBuffer,
                                                indexBufferOffset: 0)
        }
    }
}
