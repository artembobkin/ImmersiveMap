// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore
import simd

/// The two polar caps of the globe.
enum GlobeCapPole: CaseIterable {
    case north
    case south
}

/// One cap's constant colour; the layout mirrors `CapParams` in Globe.metal.
struct GlobeCapParams {
    var color: SIMD4<Float>
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
        palette = Self.makePalette(mapBaseColors: mapBaseColors)
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              globeFrame: GlobeFrameConstantsUniform,
              globe: GlobeUniform) {
        pipeline.selectPipeline(renderEncoder: renderEncoder)
        // Both caps carry the same winding seen from outside the sphere (the
        // generator flips the south fan), so back-face culling removes the
        // far half of each polar fan the way it removes the tiles' far side:
        // nothing writes surface depth on the sphere, and without the cull
        // the back of the fan would draw through the planet.
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)
        var globeFrame = globeFrame
        var globe = globe
        renderEncoder.setVertexBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 2)
        renderEncoder.setVertexBytes(&globeFrame,
                                     length: MemoryLayout<GlobeFrameConstantsUniform>.stride,
                                     index: 10)

        for pole in GlobeCapPole.allCases {
            switch pole {
            case .north: drawNorthCap(renderEncoder: renderEncoder)
            case .south: drawSouthCap(renderEncoder: renderEncoder)
            }
        }
        // The world pass shares one encoder; restore the defaults the later
        // layers rely on, the way the tile drawer does.
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)
    }

    /// Constant cap colours from the style: the north cap is the palette's
    /// open ocean, the south its polar ice (ImmersiveMapBaseColors decides),
    /// each composited to opaque over its natural background.
    static func makePalette(mapBaseColors: ImmersiveMapBaseColors) -> GlobeCapPalette {
        let northComposite = compositeOpaqueColor(foreground: mapBaseColors.getNorthPoleColor(),
                                                  background: mapBaseColors.getWaterColor())
        let southComposite = compositeOpaqueColor(foreground: mapBaseColors.getSouthPoleColor(),
                                                  background: mapBaseColors.getTileBgColor())
        return GlobeCapPalette(north: GlobeCapParams(color: northComposite),
                               south: GlobeCapParams(color: southComposite))
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
