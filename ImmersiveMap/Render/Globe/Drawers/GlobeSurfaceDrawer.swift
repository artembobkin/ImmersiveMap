// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum GlobeSurfaceDrawer {
    /// Blank tiles in the map's background color for the target slots of the
    /// globe surface, drawn before the tile geometry. A tile that has not
    /// arrived (or a hole in coverage) then reads as blank map rather than as
    /// a window into space, and the depth the fill writes is the surface depth
    /// everything else (the tile geometry, routes, scene models, the label
    /// occlusion prepass) tests against.
    ///
    /// A slot a tile placement already paints draws depth-only, with no
    /// fragment stage at all: every pixel of it is about to be painted by the
    /// placement's ground anyway (the tile background quad covers the whole
    /// slot), so shading the fill there was pure overdraw. The colour fill
    /// remains for uncovered slots. At the very limb the covered slots' tile
    /// chords can sag inside the grid's silhouette by a pixel or two, where
    /// the pass clear colour now shows instead of the map colour.
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
                                     fillColor: SIMD4<Float>,
                                     slots: [Tile],
                                     coveredSlots: Set<Tile>,
                                     pureSphere: Bool,
                                     globeFrame: GlobeFrameConstantsUniform) {
        guard slots.isEmpty == false else {
            return
        }
        var cameraUniformValue = cameraUniform
        var earthSceneValue = earthScene
        var globeValue = globe
        var horizonFogValue = horizonFog
        var atmosphereValue = atmosphere
        var fillColorValue = fillColor

        // The grid is counter-clockwise on screen on the near side of the
        // sphere (SphereGeometry.createGrid, v growing south) and clockwise
        // on the far side. Declared explicitly rather than as `.front` under
        // the default winding: the same cut, but no longer depending on no
        // earlier layer of the shared encoder having changed the front face.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        var globeFrameValue = globeFrame
        renderEncoder.setVertexBytes(&globeFrameValue,
                                     length: MemoryLayout<GlobeFrameConstantsUniform>.stride,
                                     index: 4)
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

        func drawSlots(_ selected: [Tile]) {
            for slot in selected {
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

        let covered = slots.filter { coveredSlots.contains($0) }
        let uncovered = slots.filter { coveredSlots.contains($0) == false }
        if covered.isEmpty == false {
            placeholderPipeline.selectDepthOnlyPipeline(renderEncoder: renderEncoder, pureSphere: pureSphere)
            drawSlots(covered)
        }
        if uncovered.isEmpty == false {
            placeholderPipeline.selectPipeline(renderEncoder: renderEncoder, pureSphere: pureSphere)
            drawSlots(uncovered)
        }
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }

}
