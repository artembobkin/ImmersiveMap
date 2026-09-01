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
}

struct GlobeCapPalette {
    var north: GlobeCapParams
    var south: GlobeCapParams
}

final class GlobeCapRenderer {
    private let pipeline: GlobeCapPipeline
    private let northCapBuffers: MapSurfaceGridBuffers
    private let southCapBuffers: MapSurfaceGridBuffers
    private let palette: GlobeCapPalette

    /// The style-independent half of the renderer: the pipeline and the polar
    /// cap grids are pure functions of the device, so one set serves every map
    /// view in the process. Only the palette bakes style colors and stays per
    /// instance.
    struct SharedResources {
        let pipeline: GlobeCapPipeline
        let northCapBuffers: MapSurfaceGridBuffers
        let southCapBuffers: MapSurfaceGridBuffers

        static func make(metalDevice: MTLDevice,
                         pixelFormat: MTLPixelFormat,
                         library: MTLLibrary,
                         sampleCount: Int,
                         maxLatitude: Double,
                         stacks: Int = 12,
                         slices: Int = 48) -> SharedResources {
            let maxLatitude = Float(maxLatitude)
            let northCap = CapGeometry.createCapGrid(stacks: stacks,
                                                     slices: slices,
                                                     isNorth: true,
                                                     maxLatitude: maxLatitude)
            let southCap = CapGeometry.createCapGrid(stacks: stacks,
                                                     slices: slices,
                                                     isNorth: false,
                                                     maxLatitude: maxLatitude)
            return SharedResources(
                pipeline: GlobeCapPipeline(metalDevice: metalDevice,
                                           pixelFormat: pixelFormat,
                                           library: library,
                                           sampleCount: sampleCount),
                northCapBuffers: MapSurfaceGridBuffers.make(metalDevice: metalDevice,
                                                            vertices: northCap.vertices,
                                                            indices: northCap.indices),
                southCapBuffers: MapSurfaceGridBuffers.make(metalDevice: metalDevice,
                                                            vertices: southCap.vertices,
                                                            indices: southCap.indices)
            )
        }
    }

    init(sharedResources: SharedResources,
         maxLatitude: Double,
         mapBaseColors: ImmersiveMapBaseColors) {
        pipeline = sharedResources.pipeline
        northCapBuffers = sharedResources.northCapBuffers
        southCapBuffers = sharedResources.southCapBuffers
        palette = Self.makePalette(mapBaseColors: mapBaseColors,
                                   maxLatitude: Float(maxLatitude))
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              cameraUniform: CameraUniform,
              globe: GlobeUniform,
              edgeStrip: GlobeCapEdgeStrip,
              stripUniform: (GlobeCapPole) -> GlobeCapStripUniform) {
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        // Cap winding differs from the globe tile mesh after geographic-latitude
        // alignment, so disabling culling keeps the patch visible on both poles.
        renderEncoder.setCullMode(.none)
        var cameraUniform = cameraUniform
        var globe = globe
        renderEncoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setVertexBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 2)

        for pole in GlobeCapPole.allCases {
            var strip = stripUniform(pole)
            renderEncoder.setFragmentTexture(edgeStrip.texture(for: pole), index: 0)
            renderEncoder.setFragmentBytes(&strip, length: MemoryLayout<GlobeCapStripUniform>.stride, index: 3)
            switch pole {
            case .north: drawNorthCap(renderEncoder: renderEncoder)
            case .south: drawSouthCap(renderEncoder: renderEncoder)
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
                                  blendEndAbsLatitude: fadeEndAbsLatitude),
            south: GlobeCapParams(edgeColor: southComposite,
                                  fillColor: southComposite,
                                  blendStartAbsLatitude: maxLatitude,
                                  blendEndAbsLatitude: fadeEndAbsLatitude)
        )
    }

    private func drawNorthCap(renderEncoder: MTLRenderCommandEncoder) {
        var capParams = palette.north
        renderEncoder.setFragmentBytes(&capParams, length: MemoryLayout<GlobeCapParams>.stride, index: 0)
        renderEncoder.setVertexBuffer(northCapBuffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: northCapBuffers.indicesCount,
                                            indexType: northCapBuffers.indexType,
                                            indexBuffer: northCapBuffers.indicesBuffer,
                                            indexBufferOffset: 0)
    }

    private func drawSouthCap(renderEncoder: MTLRenderCommandEncoder) {
        var capParams = palette.south
        renderEncoder.setFragmentBytes(&capParams, length: MemoryLayout<GlobeCapParams>.stride, index: 0)
        renderEncoder.setVertexBuffer(southCapBuffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: southCapBuffers.indicesCount,
                                            indexType: southCapBuffers.indexType,
                                            indexBuffer: southCapBuffers.indicesBuffer,
                                            indexBufferOffset: 0)
    }

    private static func compositeOpaqueColor(foreground: SIMD4<Float>,
                                             background: SIMD4<Float>) -> SIMD4<Float> {
        let alpha = simd_clamp(foreground.w, 0, 1)
        let rgb = foreground.xyz * alpha + background.xyz * (1 - alpha)
        return SIMD4<Float>(rgb, 1)
    }
}
