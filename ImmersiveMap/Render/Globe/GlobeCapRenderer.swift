// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore
import simd

struct GlobeCapParams {
    var edgeColor: SIMD4<Float>
    var fillColor: SIMD4<Float>
    var blendStartAbsLatitude: Float
    var blendEndAbsLatitude: Float
    var sampleOptions = SIMD4<Float>(0, 0, 0, 0)
}

struct GlobeCapPalette {
    var north: GlobeCapParams
    var south: GlobeCapParams
}

final class GlobeCapRenderer {
    private let pipeline: GlobeCapPipeline
    private let northCapBuffers: MapSurfaceGridBuffers
    private let southCapBuffers: MapSurfaceGridBuffers
    private let fallbackTexture: MTLTexture
    private let palette: GlobeCapPalette

    init(metalDevice: MTLDevice,
         layer: CAMetalLayer,
         library: MTLLibrary,
         sampleCount: Int = 1,
         maxLatitude: Double,
         mapBaseColors: ImmersiveMapBaseColors,
         stacks: Int = 12,
         slices: Int = 48) {
        pipeline = GlobeCapPipeline(metalDevice: metalDevice,
                                    layer: layer,
                                    library: library,
                                    sampleCount: sampleCount)
        fallbackTexture = Self.makeFallbackTexture(metalDevice: metalDevice)

        let maxLatitude = Float(maxLatitude)
        let northCap = CapGeometry.createCapGrid(stacks: stacks,
                                                 slices: slices,
                                                 isNorth: true,
                                                 maxLatitude: maxLatitude)
        let southCap = CapGeometry.createCapGrid(stacks: stacks,
                                                 slices: slices,
                                                 isNorth: false,
                                                 maxLatitude: maxLatitude)

        northCapBuffers = MapSurfaceGridBuffers(
            verticesBuffer: metalDevice.makeBuffer(
                bytes: northCap.vertices,
                length: MemoryLayout<CapGeometry.Vertex>.stride * northCap.vertices.count
            )!,
            indicesBuffer: metalDevice.makeBuffer(
                bytes: northCap.indices,
                length: MemoryLayout<UInt32>.stride * northCap.indices.count
            )!,
            indicesCount: northCap.indices.count
        )
        southCapBuffers = MapSurfaceGridBuffers(
            verticesBuffer: metalDevice.makeBuffer(
                bytes: southCap.vertices,
                length: MemoryLayout<CapGeometry.Vertex>.stride * southCap.vertices.count
            )!,
            indicesBuffer: metalDevice.makeBuffer(
                bytes: southCap.indices,
                length: MemoryLayout<UInt32>.stride * southCap.indices.count
            )!,
            indicesCount: southCap.indices.count
        )

        palette = Self.makePalette(mapBaseColors: mapBaseColors,
                                   maxLatitude: maxLatitude)
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              cameraUniform: CameraUniform,
              globe: GlobeUniform,
              earthScene: EarthSceneUniform,
              tilesTexture: GlobeTilesTexture) {
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        // Cap winding differs from the globe tile mesh after geographic-latitude
        // alignment, so disabling culling keeps the patch visible on both poles.
        renderEncoder.setCullMode(.none)
        var cameraUniform = cameraUniform
        var globe = globe
        var earthScene = earthScene
        renderEncoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setFragmentBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&earthScene, length: MemoryLayout<EarthSceneUniform>.stride, index: 2)

        var fallbackTileData = Self.makeFallbackTileData()
        renderEncoder.setFragmentTexture(fallbackTexture, index: 0)
        renderEncoder.setFragmentBytes(&fallbackTileData, length: MemoryLayout<GlobeTilesTexture.TileData>.stride, index: 3)
        drawCapPair(renderEncoder: renderEncoder, textureSamplingEnabled: false)

        let pageMappings = GlobeTilePageMappingSorter.sortedPageMappings(tilesTexture: tilesTexture)
        var activePageIndex: Int?
        for pageMapping in pageMappings {
            if activePageIndex != pageMapping.pageIndex {
                renderEncoder.setFragmentTexture(tilesTexture.pages[pageMapping.pageIndex].texture, index: 0)
                activePageIndex = pageMapping.pageIndex
            }

            var mapping = pageMapping.mapping
            renderEncoder.setFragmentBytes(&mapping, length: MemoryLayout<GlobeTilesTexture.TileData>.stride, index: 3)
            let lastTileY = (1 << Int(mapping.tile.z)) - 1
            if mapping.tile.y == 0 {
                drawNorthCap(renderEncoder: renderEncoder, textureSamplingEnabled: true)
            }
            if Int(mapping.tile.y) == lastTileY {
                drawSouthCap(renderEncoder: renderEncoder, textureSamplingEnabled: true)
            }
        }
    }

    static func makePalette(mapBaseColors: ImmersiveMapBaseColors,
                            maxLatitude: Float,
                            featherDegrees: Float = 6.0) -> GlobeCapPalette {
        let waterColor = mapBaseColors.getWaterColor()
        let tileBackgroundColor = mapBaseColors.getTileBgColor()
        let northPoleColor = mapBaseColors.getNorthPoleColor()
        let southPoleColor = mapBaseColors.getSouthPoleColor()
        let featherRadians = featherDegrees * (.pi / 180.0)
        let fadeEndAbsLatitude = min(Float.pi / 2.0, maxLatitude + featherRadians)
        let northComposite = compositeOpaqueColor(foreground: northPoleColor,
                                                  background: waterColor)
        let southComposite = compositeOpaqueColor(foreground: southPoleColor,
                                                  background: tileBackgroundColor)

        return GlobeCapPalette(
            north: GlobeCapParams(edgeColor: northComposite,
                                  fillColor: northComposite,
                                  blendStartAbsLatitude: maxLatitude,
                                  blendEndAbsLatitude: fadeEndAbsLatitude,
                                  sampleOptions: SIMD4<Float>(maxLatitude, 0, 0, 0)),
            south: GlobeCapParams(edgeColor: southComposite,
                                  fillColor: southComposite,
                                  blendStartAbsLatitude: maxLatitude,
                                  blendEndAbsLatitude: fadeEndAbsLatitude,
                                  sampleOptions: SIMD4<Float>(-maxLatitude, 0, 0, 0))
        )
    }

    private func drawCapPair(renderEncoder: MTLRenderCommandEncoder,
                             textureSamplingEnabled: Bool) {
        drawNorthCap(renderEncoder: renderEncoder, textureSamplingEnabled: textureSamplingEnabled)
        drawSouthCap(renderEncoder: renderEncoder, textureSamplingEnabled: textureSamplingEnabled)
    }

    private func drawNorthCap(renderEncoder: MTLRenderCommandEncoder,
                              textureSamplingEnabled: Bool) {
        let textureSampleFlag: Float = textureSamplingEnabled ? 1 : 0

        var capParams = palette.north
        capParams.sampleOptions.y = textureSampleFlag
        renderEncoder.setFragmentBytes(&capParams, length: MemoryLayout<GlobeCapParams>.stride, index: 0)
        renderEncoder.setVertexBuffer(northCapBuffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: northCapBuffers.indicesCount,
                                            indexType: .uint32,
                                            indexBuffer: northCapBuffers.indicesBuffer,
                                            indexBufferOffset: 0)
    }

    private func drawSouthCap(renderEncoder: MTLRenderCommandEncoder,
                              textureSamplingEnabled: Bool) {
        let textureSampleFlag: Float = textureSamplingEnabled ? 1 : 0

        var capParams = palette.south
        capParams.sampleOptions.y = textureSampleFlag
        renderEncoder.setFragmentBytes(&capParams, length: MemoryLayout<GlobeCapParams>.stride, index: 0)
        renderEncoder.setVertexBuffer(southCapBuffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: southCapBuffers.indicesCount,
                                            indexType: .uint32,
                                            indexBuffer: southCapBuffers.indicesBuffer,
                                            indexBufferOffset: 0)
    }

    private static func makeFallbackTileData() -> GlobeTilesTexture.TileData {
        GlobeTilesTexture.TileData(position: simd_int1(0),
                                   textureSize: simd_int1(1),
                                   cellSize: simd_int1(1),
                                   tile: simd_int3(0, 0, 0),
                                   sourceTile: simd_int3(0, 0, 0))
    }

    private static func makeFallbackTexture(metalDevice: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 1,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = metalDevice.makeTexture(descriptor: descriptor)!
        var pixel: UInt32 = 0xFFFFFFFF
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                        mipmapLevel: 0,
                        withBytes: &pixel,
                        bytesPerRow: MemoryLayout<UInt32>.stride)
        return texture
    }

    private static func compositeOpaqueColor(foreground: SIMD4<Float>,
                                             background: SIMD4<Float>) -> SIMD4<Float> {
        let alpha = simd_clamp(foreground.w, 0, 1)
        let rgb = foreground.xyz * alpha + background.xyz * (1 - alpha)
        return SIMD4<Float>(rgb, 1)
    }
}
