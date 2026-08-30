// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The globe counterpart of `FlatMapSurfaceDrawer`: every placement's ground
/// layer (below tile z8 the whole drawable content of a tile lives there)
/// through the sphere tile pipeline. Bindings mirror TileSphere.metal.
enum GlobeVectorSurfaceDrawer {
    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     globe: GlobeUniform,
                     earthScene: EarthSceneUniform,
                     atmosphere: GlobeAtmosphereUniform,
                     tone: GlobeSurfaceToneUniform,
                     horizonFog: HorizonFogUniform,
                     cameraZoom: Double,
                     pixelsPerPoint: Float,
                     drawableHeightPx: Float,
                     renderMapSize: Double,
                     placeTilesContext: PlaceTilesContext,
                     pipeline: TilePipeline,
                     isWireframeEnabled: Bool) {
        guard placeTilesContext.tilePlacements.isEmpty == false else {
            return
        }
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        // Every tile triangle is counter-clockwise in render space (the
        // parser's contract, ParsedPolygon.firstClockwiseTriangle) and the
        // sphere projection does not mirror, so the near side of the planet
        // is counter-clockwise on screen and the far side clockwise: culling
        // back faces removes the far side by orientation alone, whatever the
        // horizon clip threshold lets through while the surface unfurls.
        // Both calls are explicit because the world pass shares one encoder
        // and the buildings rely on Metal's default front face.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }

        var cameraUniformValue = cameraUniform
        var globeValue = globe
        var earthSceneValue = earthScene
        var atmosphereValue = atmosphere
        var toneValue = tone
        var horizonFogValue = horizonFog
        var streetPaletteUniform = StreetPaletteUniform(
            blend: LowZoomOverviewFade.streetPaletteBlend(for: cameraZoom)
        )
        // Point-locked widths resolve against the real screen gradient of the
        // line field (fwidth in the coverage), so the taper is all the sphere
        // needs; the atlas's per-slot texel scales were artifacts of baking
        // into a flat orthographic slot. Every road is a symbol at these
        // zooms and no road is painted yet: the surface blend and the
        // marking alpha stay zero, as they were in the atlas.
        var overviewFadeUniform = TileOverviewFadeUniform(
            overviewAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .overviewFeatures),
            roadAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .roads),
            landuseAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .landuse),
            pixelsPerPoint: pixelsPerPoint * LineWidthZoomTaper.scale(for: cameraZoom),
            cameraZoom: Float(cameraZoom)
        )
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&streetPaletteUniform, length: MemoryLayout<StreetPaletteUniform>.stride, index: 6)
        renderEncoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        renderEncoder.setFragmentBytes(&overviewFadeUniform, length: MemoryLayout<TileOverviewFadeUniform>.stride, index: 0)
        renderEncoder.setFragmentBytes(&horizonFogValue, length: MemoryLayout<HorizonFogUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 5)
        renderEncoder.setFragmentBytes(&earthSceneValue, length: MemoryLayout<EarthSceneUniform>.stride, index: 6)
        renderEncoder.setFragmentBytes(&atmosphereValue, length: MemoryLayout<GlobeAtmosphereUniform>.stride, index: 7)
        renderEncoder.setFragmentBytes(&toneValue, length: MemoryLayout<GlobeSurfaceToneUniform>.stride, index: 8)

        for placeTile in placeTilesContext.tilePlacements {
            let metalTile = placeTile.metalTile
            let buffers = metalTile.tileBuffers.ground
            guard buffers.indicesCount > 0,
                  let indices = buffers.indices,
                  let vertices = buffers.vertices,
                  let styles = buffers.styles,
                  let overviewStyleMask = buffers.overviewStyleMask,
                  let lineStyles = buffers.lineStyles else { continue }

            let tile = metalTile.tile
            renderEncoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
            renderEncoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
            renderEncoder.setVertexBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 4)
            renderEncoder.setVertexBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 5)

            // The vertices are in the source tile's space; a retained
            // substitute is clipped to its placeIn slot by the rasterizer.
            var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placeTile.placeIn.tile)
            renderEncoder.setVertexBytes(&localClipBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 7)
            var surfaceTile = GlobeSurfaceTileUniform(tile: tile)
            renderEncoder.setVertexBytes(&surfaceTile, length: MemoryLayout<GlobeSurfaceTileUniform>.stride, index: 9)

            // The dash anchor of the flat path, with the source tile's world
            // size on the equator: the pattern holds still under camera
            // motion and matches the plane at the surface swap.
            let sourceTileWorldSize = Float(renderMapSize / Double(1 << tile.z))
            var lineDashUniform = LineDashUniform(
                unitsPerPoint: GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: tile.z)
                    * pixelsPerPoint
                    * LineDashNominalScale.unitsPerPixel(sourceTileWorldSize: sourceTileWorldSize,
                                                         drawableHeightPx: drawableHeightPx)
            )
            renderEncoder.setFragmentBytes(&lineDashUniform, length: MemoryLayout<LineDashUniform>.stride, index: 4)

            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: indices.count,
                                                indexType: buffers.indexType,
                                                indexBuffer: indices.buffer,
                                                indexBufferOffset: indices.offset)
        }
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }
}
