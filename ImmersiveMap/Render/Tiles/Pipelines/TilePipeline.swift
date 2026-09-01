// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class TilePipeline {
    /// Which surface the pipeline draws tiles onto. The flat one projects
    /// through a model matrix into the plane (Tile.metal); the sphere one
    /// projects tile-local positions onto the globe through the surface
    /// morph (TileSphere.metal). Same vertex format, styles and blending.
    enum Surface {
        case flat
        case sphere
    }

    let pipelineState: MTLRenderPipelineState
    /// Variant for the framebuffer-fetch world pass (Apple GPUs, nil
    /// elsewhere): identical, but declares the pass's second building
    /// attachment with an empty write mask so the pipeline stays
    /// pass-compatible.
    let withBuildingImagePipelineState: MTLRenderPipelineState?
    /// Sphere surface only: the resting-sphere combined pass
    /// (tileSpherePureVertexShader, both classes), the fallback when the
    /// split is not used. The morph keeps `pipelineState`
    /// (tileSphereMorphVertexShader), the only sphere variant with the
    /// unroll and the fog.
    let sphereUnlitPipelineState: MTLRenderPipelineState?
    /// Sphere surface only: resting-sphere split variants drawing one
    /// ground class each (fills or line ribbons), indexed by linesClass.
    /// The scaffold the globe performance work isolates the classes with;
    /// see kTileSphereSplitPass in TileSphere.metal.
    let sphereSplitStates: [Bool: MTLRenderPipelineState]
    /// The fills class with blending disabled: what the opaque ground
    /// layers draw with, front-to-back under the depth test.
    let sphereOpaqueFillsPipelineState: MTLRenderPipelineState?

    /// - Parameter readsGroundShadowMask: the flat world pass reads the
    ///   per-pixel ground shadow mask at fragment texture 1; the globe atlas
    ///   bake keeps the direct cascade sampling path (with a disabled uniform)
    ///   and only binds the shadow map slot.
    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         supportsFramebufferFetch: Bool = false,
         readsGroundShadowMask: Bool = false,
         surface: Surface = .flat) {
        let vertexFunction: MTLFunction?
        let fragmentFunction: MTLFunction?
        var sphereUnlitFragmentFunction: MTLFunction?
        var sphereUnlitPureVertexFunction: MTLFunction?
        var sphereTempSplitVertexFunctions: [Bool: MTLFunction] = [:]
        var sphereTempSplitFragmentFunctions: [Bool: MTLFunction] = [:]
        switch surface {
        case .flat:
            vertexFunction = library.makeFunction(name: "tileVertexShader")
            let constantValues = MTLFunctionConstantValues()
            var readsMask = readsGroundShadowMask
            constantValues.setConstantValue(&readsMask, type: .bool, index: 0)
            fragmentFunction = try! library.makeFunction(name: "tileFragmentShader", constantValues: constantValues)
        case .sphere:
            func sphereConstants(fog: Bool, lineFields: Bool, split: Bool, linesClass: Bool) -> MTLFunctionConstantValues {
                let values = MTLFunctionConstantValues()
                var fogValue = fog
                var lineFieldsValue = lineFields
                var splitValue = split
                var linesValue = linesClass
                values.setConstantValue(&fogValue, type: .bool, index: 0)
                values.setConstantValue(&lineFieldsValue, type: .bool, index: 1)
                values.setConstantValue(&splitValue, type: .bool, index: 2)
                values.setConstantValue(&linesValue, type: .bool, index: 3)
                return values
            }
            func sphereFunction(_ name: String, fog: Bool, lineFields: Bool,
                                split: Bool = false, linesClass: Bool = false) -> MTLFunction {
                try! library.makeFunction(name: name,
                                          constantValues: sphereConstants(fog: fog,
                                                                          lineFields: lineFields,
                                                                          split: split,
                                                                          linesClass: linesClass))
            }
            // The morph: the only sphere variant with the unroll and the fog.
            vertexFunction = sphereFunction("tileSphereMorphVertexShader", fog: true, lineFields: true)
            fragmentFunction = sphereFunction("tileSphereFragmentShader", fog: true, lineFields: true)
            // The resting sphere, combined classes.
            sphereUnlitPureVertexFunction = sphereFunction("tileSpherePureVertexShader", fog: false, lineFields: true)
            sphereUnlitFragmentFunction = sphereFunction("tileSphereFragmentShader", fog: false, lineFields: true)
            // The split vertex variants, one ground class each; the fills
            // class carries no line fields at all.
            sphereTempSplitVertexFunctions = [
                false: sphereFunction("tileSpherePureVertexShader", fog: false, lineFields: false,
                                      split: true, linesClass: false),
                true: sphereFunction("tileSpherePureVertexShader", fog: false, lineFields: true,
                                     split: true, linesClass: true)
            ]
            sphereTempSplitFragmentFunctions = [
                false: sphereFunction("tileSphereFragmentShader", fog: false, lineFields: false),
                true: sphereFunction("tileSphereFragmentShader", fog: false, lineFields: true)
            ]
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .short2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .uchar
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Int16>>.size
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .char
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD2<Int16>>.size + 1
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .short
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD2<Int16>>.size + 2
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<TileVertexIn>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        // Alpha blends with .one so coverage accumulates on a transparent
        // destination; over an opaque one the result is unchanged.
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        if let sphereUnlitPureVertexFunction, let sphereUnlitFragmentFunction {
            pipelineDescriptor.vertexFunction = sphereUnlitPureVertexFunction
            pipelineDescriptor.fragmentFunction = sphereUnlitFragmentFunction
            self.sphereUnlitPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            // The split pipeline states, one ground class each; the fills
            // fragment carries no line fields either.
            var splitStates: [Bool: MTLRenderPipelineState] = [:]
            for (lines, vertex) in sphereTempSplitVertexFunctions {
                pipelineDescriptor.vertexFunction = vertex
                pipelineDescriptor.fragmentFunction = sphereTempSplitFragmentFunctions[lines]
                splitStates[lines] = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            }
            self.sphereSplitStates = splitStates
            // The opaque fills variant: same functions, no blending.
            pipelineDescriptor.vertexFunction = sphereTempSplitVertexFunctions[false]
            pipelineDescriptor.fragmentFunction = sphereTempSplitFragmentFunctions[false]
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
            self.sphereOpaqueFillsPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
        } else {
            self.sphereUnlitPipelineState = nil
            self.sphereSplitStates = [:]
            self.sphereOpaqueFillsPipelineState = nil
        }

        if supportsFramebufferFetch, surface == .flat {
            pipelineDescriptor.colorAttachments[1].pixelFormat = pixelFormat
            pipelineDescriptor.colorAttachments[1].writeMask = []
            self.withBuildingImagePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } else {
            self.withBuildingImagePipelineState = nil
        }
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder,
                        withBuildingImageAttachment: Bool = false) {
        if withBuildingImageAttachment, let withBuildingImagePipelineState {
            renderEncoder.setRenderPipelineState(withBuildingImagePipelineState)
            return
        }
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    /// The opaque fills variant (blending off) for the layered ground;
    /// falls back to the blended fills split when absent.
    func selectSphereOpaqueFillsPipeline(renderEncoder: MTLRenderCommandEncoder) {
        if let sphereOpaqueFillsPipelineState {
            renderEncoder.setRenderPipelineState(sphereOpaqueFillsPipelineState)
            return
        }
        selectSphereSplitPipeline(renderEncoder: renderEncoder, linesClass: false)
    }

    /// The unlit pure-sphere split variant for one ground class; falls back
    /// to the regular selection when the variants are absent.
    func selectSphereSplitPipeline(renderEncoder: MTLRenderCommandEncoder,
                                   linesClass: Bool) {
        if let state = sphereSplitStates[linesClass] {
            renderEncoder.setRenderPipelineState(state)
            return
        }
        selectSpherePipeline(renderEncoder: renderEncoder, pureSphere: true)
    }

    /// The sphere variant for the frame: the pure sphere blends unlit under
    /// the deferred lighting pass, the unfurl lights inline. Falls back to
    /// the full pipeline on a surface that has no variants.
    func selectSpherePipeline(renderEncoder: MTLRenderCommandEncoder,
                              pureSphere: Bool) {
        if pureSphere, let sphereUnlitPipelineState {
            renderEncoder.setRenderPipelineState(sphereUnlitPipelineState)
            return
        }
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
