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
    /// Sphere surface only: the resting-sphere fills class, blended (the
    /// translucent fill layers). Carries no line fields. The morph keeps
    /// `pipelineState` (tileSphereMorphVertexShader), the only sphere
    /// variant with the unroll and the fog.
    let sphereFillsPipelineState: MTLRenderPipelineState?
    /// The fills class with blending disabled: what the opaque ground
    /// layers draw with, front-to-back under the depth test.
    let sphereOpaqueFillsPipelineState: MTLRenderPipelineState?
    /// The resting-sphere ribbons class: the line ribbons of the ground
    /// bucket through the line-field coverage, blended.
    let sphereRibbonsPipelineState: MTLRenderPipelineState?
    /// The morph's class variants: the same layered passes as the resting
    /// sphere (the unroll never self-intersects toward the camera, so the
    /// rank depth band applies unchanged), with the unroll and the fog.
    let sphereMorphFillsPipelineState: MTLRenderPipelineState?
    let sphereMorphOpaqueFillsPipelineState: MTLRenderPipelineState?
    let sphereMorphRibbonsPipelineState: MTLRenderPipelineState?

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
        var spherePureVertexFunctions: [Bool: MTLFunction] = [:]
        var spherePureFragmentFunctions: [Bool: MTLFunction] = [:]
        var sphereMorphVertexFunctions: [Bool: MTLFunction] = [:]
        var sphereMorphFragmentFunctions: [Bool: MTLFunction] = [:]
        switch surface {
        case .flat:
            vertexFunction = library.makeFunction(name: "tileVertexShader")
            let constantValues = MTLFunctionConstantValues()
            var readsMask = readsGroundShadowMask
            constantValues.setConstantValue(&readsMask, type: .bool, index: 0)
            fragmentFunction = try! library.makeFunction(name: "tileFragmentShader", constantValues: constantValues)
        case .sphere:
            func sphereFunction(_ name: String, fog: Bool, lineFields: Bool) -> MTLFunction {
                let values = MTLFunctionConstantValues()
                var fogValue = fog
                var lineFieldsValue = lineFields
                values.setConstantValue(&fogValue, type: .bool, index: 0)
                values.setConstantValue(&lineFieldsValue, type: .bool, index: 1)
                return try! library.makeFunction(name: name, constantValues: values)
            }
            // The morph: the sphere variants with the unroll and the fog.
            vertexFunction = sphereFunction("tileSphereMorphVertexShader", fog: true, lineFields: true)
            fragmentFunction = sphereFunction("tileSphereFragmentShader", fog: true, lineFields: true)
            // The class variants, keyed by lineFields: the fills class
            // carries no line fields at all, the ribbons class carries the
            // analytic line coverage. The morph pair adds the fog.
            spherePureVertexFunctions = [
                false: sphereFunction("tileSpherePureVertexShader", fog: false, lineFields: false),
                true: sphereFunction("tileSpherePureVertexShader", fog: false, lineFields: true)
            ]
            spherePureFragmentFunctions = [
                false: sphereFunction("tileSphereFragmentShader", fog: false, lineFields: false),
                true: sphereFunction("tileSphereFragmentShader", fog: false, lineFields: true)
            ]
            sphereMorphVertexFunctions = [
                false: sphereFunction("tileSphereMorphVertexShader", fog: true, lineFields: false),
                true: vertexFunction!
            ]
            sphereMorphFragmentFunctions = [
                false: sphereFunction("tileSphereFragmentShader", fog: true, lineFields: false),
                true: fragmentFunction!
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

        if spherePureVertexFunctions.isEmpty == false {
            func makeClassStates(vertexFns: [Bool: MTLFunction],
                                 fragmentFns: [Bool: MTLFunction]) -> (fills: MTLRenderPipelineState,
                                                                       opaqueFills: MTLRenderPipelineState,
                                                                       ribbons: MTLRenderPipelineState) {
                pipelineDescriptor.vertexFunction = vertexFns[false]
                pipelineDescriptor.fragmentFunction = fragmentFns[false]
                let fills = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
                // The opaque fills variant: same functions, no blending.
                pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
                let opaqueFills = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
                pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
                pipelineDescriptor.vertexFunction = vertexFns[true]
                pipelineDescriptor.fragmentFunction = fragmentFns[true]
                let ribbons = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
                return (fills, opaqueFills, ribbons)
            }
            let pure = makeClassStates(vertexFns: spherePureVertexFunctions,
                                       fragmentFns: spherePureFragmentFunctions)
            self.sphereFillsPipelineState = pure.fills
            self.sphereOpaqueFillsPipelineState = pure.opaqueFills
            self.sphereRibbonsPipelineState = pure.ribbons
            let morph = makeClassStates(vertexFns: sphereMorphVertexFunctions,
                                        fragmentFns: sphereMorphFragmentFunctions)
            self.sphereMorphFillsPipelineState = morph.fills
            self.sphereMorphOpaqueFillsPipelineState = morph.opaqueFills
            self.sphereMorphRibbonsPipelineState = morph.ribbons
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
        } else {
            self.sphereFillsPipelineState = nil
            self.sphereOpaqueFillsPipelineState = nil
            self.sphereRibbonsPipelineState = nil
            self.sphereMorphFillsPipelineState = nil
            self.sphereMorphOpaqueFillsPipelineState = nil
            self.sphereMorphRibbonsPipelineState = nil
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
    /// falls back to the blended fills variant when absent.
    func selectSphereOpaqueFillsPipeline(renderEncoder: MTLRenderCommandEncoder,
                                         morph: Bool) {
        let state = morph ? sphereMorphOpaqueFillsPipelineState : sphereOpaqueFillsPipelineState
        if let state {
            renderEncoder.setRenderPipelineState(state)
            return
        }
        selectSphereClassPipeline(renderEncoder: renderEncoder, linesClass: false, morph: morph)
    }

    /// The sphere variant for one ground class, on the resting sphere or
    /// the morph; falls back to the combined morph pipeline on a surface
    /// that has no variants.
    func selectSphereClassPipeline(renderEncoder: MTLRenderCommandEncoder,
                                   linesClass: Bool,
                                   morph: Bool) {
        let state: MTLRenderPipelineState?
        if morph {
            state = linesClass ? sphereMorphRibbonsPipelineState : sphereMorphFillsPipelineState
        } else {
            state = linesClass ? sphereRibbonsPipelineState : sphereFillsPipelineState
        }
        if let state {
            renderEncoder.setRenderPipelineState(state)
            return
        }
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
