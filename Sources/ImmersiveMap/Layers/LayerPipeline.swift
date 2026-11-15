// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The pipelines of the layers of the app's data (Layers.metal): zones,
/// lines and discs, each in one variant per surface the ground is drawn on
/// (`Surface`), in the world pass's formats and sample count, blended like
/// the ground. The shaders read their vertices from buffers by index, so
/// no vertex descriptor.
final class LayerPipeline {
    /// Mirrors `kLayerSurface` in Layers.metal.
    enum Surface: Int, CaseIterable {
        case flat = 0
        case sphere = 1
        case morph = 2
    }

    struct States {
        let fill: MTLRenderPipelineState
        let line: MTLRenderPipelineState
        let point: MTLRenderPipelineState
    }

    private let statesBySurface: [Surface: States]
    /// How a layer is tested where it draws: never against the ground's
    /// depth (`overGround`) or against it, so the relief nearer the camera
    /// hides it (`behindTerrain`, `ImmersiveMapLayer.hidesBehindTerrain`).
    /// Both test the surface mask bit the buildings, the models and the
    /// trees raise where they stand (`TileSourceStencilPriority`), as the
    /// roads do, so whatever stands in front of a layer covers it, and
    /// neither writes depth or stencil. The reference is zero.
    let overGroundState: MTLDepthStencilState
    let behindTerrainState: MTLDepthStencilState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int) {
        let descriptor = MTLRenderPipelineDescriptor()
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

        func makeState(vertex: String, fragment: String, surface: Surface, blends: Bool = true) -> MTLRenderPipelineState {
            descriptor.colorAttachments[0].isBlendingEnabled = blends
            let values = MTLFunctionConstantValues()
            var surfaceValue = Int32(surface.rawValue)
            values.setConstantValue(&surfaceValue, type: .int, index: 0)
            descriptor.vertexFunction = try! library.makeFunction(name: vertex, constantValues: values)
            descriptor.fragmentFunction = try! library.makeFunction(name: fragment, constantValues: values)
            return try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        }
        var states: [Surface: States] = [:]
        for surface in Surface.allCases {
            states[surface] = States(fill: makeState(vertex: "layerFillVertex", fragment: "layerFillFragment", surface: surface),
                                     // A line is solid and its shape is its geometry, so
                                     // it draws without blending (`layerLineFragment`).
                                     line: makeState(vertex: "layerLineVertex", fragment: "layerLineFragment", surface: surface,
                                                     blends: false),
                                     point: makeState(vertex: "layerPointVertex", fragment: "layerPointFragment", surface: surface))
        }
        statesBySurface = states
        lineTemplateIndices = Self.lineTemplate.withUnsafeBytes { bytes in
            metalDevice.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)!
        }
        lineTemplateIndices.label = "Layer line template"

        func makeDepthState(testsDepth: Bool) -> MTLDepthStencilState {
            let stencil = MTLStencilDescriptor()
            stencil.stencilCompareFunction = .equal
            stencil.stencilFailureOperation = .keep
            stencil.depthFailureOperation = .keep
            stencil.depthStencilPassOperation = .keep
            stencil.readMask = TileSourceStencilPriority.surfaceMaskBit
            stencil.writeMask = 0
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = testsDepth ? .less : .always
            descriptor.isDepthWriteEnabled = false
            descriptor.frontFaceStencil = stencil
            descriptor.backFaceStencil = stencil
            return metalDevice.makeDepthStencilState(descriptor: descriptor)!
        }
        overGroundState = makeDepthState(testsDepth: false)
        behindTerrainState = makeDepthState(testsDepth: true)
    }

    /// The triangles of one segment's shape, over the ten corners the
    /// vertex stage places (`kLayerLineCorners` in Layers.metal): the body,
    /// then half an octagon at the start and one at the end.
    static let lineTemplate: [UInt16] = [0, 1, 5, 5, 1, 6,
                                         0, 2, 4, 0, 4, 3, 0, 3, 1,
                                         5, 7, 9, 5, 9, 8, 5, 8, 6]
    /// `lineTemplate` on the GPU, the index buffer every segment draws by.
    let lineTemplateIndices: MTLBuffer

    func states(for surface: Surface) -> States {
        statesBySurface[surface]!
    }
}

/// Mirrors `LayerDraw` in Layers.metal: one chunk's draw state.
struct LayerDrawUniform {
    var modelMatrix: matrix_float4x4
    var uvOrigin: SIMD2<Float>
    var uvScale: Float
    var referenceWorldX: Float
    var viewportSizePx: SIMD2<Float>
    var pixelsPerPoint: Float
    var depth: Float
}

/// Where the layers sit in the ground's far-plane depth band: a step
/// behind the labels painted on the map (`SurfaceLabelDepth`), which draw
/// over them, and nearer than the ground and the roads, so a layer lies
/// over those and every building and model stays in front of it.
enum LayerDepth {
    static let depth: Float = 1 - GlobeSurfaceDepthRank.appLayersRank * GlobeSurfaceDepthRank.layerDepthStep
}
