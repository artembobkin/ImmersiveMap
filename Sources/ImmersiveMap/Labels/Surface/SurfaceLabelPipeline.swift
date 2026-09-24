// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The pipelines of the labels painted on the map (SurfaceLabel.metal): one
/// per surface the ground is drawn on, all in the world pass's formats and
/// sample count, blended like the ground.
final class SurfaceLabelPipeline {
    let flatPipelineState: MTLRenderPipelineState
    let spherePipelineState: MTLRenderPipelineState
    let morphPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int) {
        // The baked vertices are `LabelVertex`: the anchor, the atlas uv and
        // the offset are all the stages read.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = MemoryLayout<LabelVertex>.offset(of: \.position)!
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<LabelVertex>.offset(of: \.uv)!
        vertexDescriptor.attributes[1].bufferIndex = 0
        // The glyph's offset from the anchor in points (`TileSurfaceLabelsBuilder`).
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<LabelVertex>.offset(of: \.spriteUV)!
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<LabelVertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.fragmentFunction = library.makeFunction(name: "surfaceLabelFragment")
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        func makeState(vertexFunction name: String) -> MTLRenderPipelineState {
            descriptor.vertexFunction = library.makeFunction(name: name)
            return try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        }
        self.flatPipelineState = makeState(vertexFunction: "surfaceLabelFlatVertex")
        self.spherePipelineState = makeState(vertexFunction: "surfaceLabelSphereVertex")
        self.morphPipelineState = makeState(vertexFunction: "surfaceLabelMorphVertex")
    }
}

/// Mirror of `SurfaceLabelDraw` in SurfaceLabel.metal.
struct SurfaceLabelDrawUniform {
    var fillColor: SIMD4<Float>
    var strokeColor: SIMD4<Float>
    var haloAtlasTexels: Float
    var depth: Float
    var haloPass: Float
    var tileUnitsPerPoint: Float
    var viewportSizePx: SIMD2<Float>
    var pixelsPerPoint: Float
    var _padding: Float = 0
}

/// How large a label painted on the map is on screen. The map's own scale
/// follows the viewport: at the camera zoom equal to a tile's own, the
/// render camera (vertical fov pi/4, at distance 1, `RenderCamera`) shows
/// the tile's world size over the viewport's height, so a tile spans the
/// same share of the height in any window. The text keeps to that scale:
/// its point size at the reference zoom, twice that one zoom deeper. The
/// vertex stage never lets it draw smaller than its point size where the
/// ground itself is small on screen (SurfaceLabel.metal).
enum SurfaceLabelScale {
    /// Screen points one tile spans at the camera zoom equal to its own.
    static func tileScreenPoints(viewportHeightPoints: Double, tileWorldSize: Double) -> Double {
        viewportHeightPoints * tileWorldSize / (2 * tan(Double.pi / 8))
    }

    /// Tile units per point of a label drawn from a tile of `tileZoom` that
    /// spans its point size at `referenceZoom`.
    static func tileUnitsPerPoint(tileZoom: Int,
                                  referenceZoom: Double,
                                  tileScreenPoints: Double) -> Float {
        let points = tileScreenPoints * pow(2, referenceZoom - Double(tileZoom))
        guard points > 0, points.isFinite else { return 0 }
        return Float(TileCoordinateSpace.tileExtentDouble / points)
    }
}

/// Where the labels painted on the map sit in the ground's far-plane depth
/// band: nearer than the ground's layers and every road sheet (whose bands
/// end about 2 900 steps of 2^-23 under one), so the text lies over them,
/// and still farther than the buildings and the models, which hide it.
enum SurfaceLabelDepth {
    static let depth: Float = 1 - 4_096 * 0x1p-23
}
