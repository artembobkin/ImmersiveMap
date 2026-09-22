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
    /// Flat surface only: the fills classes without the line fields (no
    /// export, no interpolation, no coverage math), blended for the
    /// translucent layers and unblended for the opaque depth pass.
    /// `pipelineState` remains the line-fields variant (ribbons, road
    /// buckets, bridge overlay).
    let flatFillsPipelineState: MTLRenderPipelineState?
    let flatOpaquePipelineState: MTLRenderPipelineState?
    /// Flat surface only: the exact rank depth variants of the three flat
    /// pipelines above (Tile.metal, kTileExactRankDepth): the fragment
    /// stage writes the layer's rank as the depth, a constant the near
    /// cut cannot move. For the sources whose triangles are too large for
    /// the vertex band, the coarse bands (FlatMapSurfaceDrawer decides by
    /// zoom).
    let flatExactPipelineState: MTLRenderPipelineState?
    let flatExactFillsPipelineState: MTLRenderPipelineState?
    let flatExactOpaquePipelineState: MTLRenderPipelineState?
    /// Flat surface only: the road sheet's two stages over the line-fields
    /// vertex stage (Tile.metal, the road sheet). The depth stage writes no
    /// colour, the colour stage blends like every other line.
    let flatRoadSheetDepthPipelineState: MTLRenderPipelineState?
    let flatRoadSheetColorPipelineState: MTLRenderPipelineState?
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
         readsGroundShadowMask: Bool = false,
         surface: Surface = .flat) {
        let vertexFunction: MTLFunction?
        let fragmentFunction: MTLFunction?
        var spherePureVertexFunctions: [Bool: MTLFunction] = [:]
        var spherePureFragmentFunctions: [Bool: MTLFunction] = [:]
        var sphereMorphVertexFunctions: [Bool: MTLFunction] = [:]
        var sphereMorphFragmentFunctions: [Bool: MTLFunction] = [:]
        var flatFillsVertexFunction: MTLFunction?
        var flatFillsFragmentFunction: MTLFunction?
        // The exact rank depth variants: the same flat classes with the
        // exact-depth fragment entry.
        var flatExactVertexFunction: MTLFunction?
        var flatExactFragmentFunction: MTLFunction?
        var flatExactFillsVertexFunction: MTLFunction?
        var flatExactFillsFragmentFunction: MTLFunction?
        var flatRoadSheetDepthFragmentFunction: MTLFunction?
        var flatRoadSheetColorFragmentFunction: MTLFunction?
        switch surface {
        case .flat:
            func flatFunction(_ name: String,
                              lineFields: Bool,
                              exactRankDepth: Bool = false) -> MTLFunction {
                let values = MTLFunctionConstantValues()
                var readsMask = readsGroundShadowMask
                var lineFieldsValue = lineFields
                var exactRankDepthValue = exactRankDepth
                values.setConstantValue(&readsMask, type: .bool, index: 0)
                values.setConstantValue(&lineFieldsValue, type: .bool, index: 1)
                values.setConstantValue(&exactRankDepthValue, type: .bool, index: 3)
                return try! library.makeFunction(name: name, constantValues: values)
            }
            vertexFunction = flatFunction("tileVertexShader", lineFields: true)
            fragmentFunction = flatFunction("tileFragmentShader", lineFields: true)
            flatFillsVertexFunction = flatFunction("tileVertexShader", lineFields: false)
            flatFillsFragmentFunction = flatFunction("tileFragmentShader", lineFields: false)
            flatExactVertexFunction = flatFunction("tileVertexShader", lineFields: true, exactRankDepth: true)
            flatExactFragmentFunction = flatFunction("tileExactDepthFragmentShader", lineFields: true, exactRankDepth: true)
            flatExactFillsVertexFunction = flatFunction("tileVertexShader", lineFields: false, exactRankDepth: true)
            flatExactFillsFragmentFunction = flatFunction("tileExactDepthFragmentShader", lineFields: false, exactRankDepth: true)
            flatRoadSheetDepthFragmentFunction = flatFunction("tileRoadSheetDepthFragmentShader", lineFields: true)
            flatRoadSheetColorFragmentFunction = flatFunction("tileRoadSheetFragmentShader", lineFields: true)
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
        // The deferred ribbons' extrusion direction, snorm to a unit float2.
        vertexDescriptor.attributes[4].format = .char2Normalized
        vertexDescriptor.attributes[4].offset = MemoryLayout<TileVertexIn>.offset(of: \.normal)!
        vertexDescriptor.attributes[4].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<TileVertexIn>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
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

        if surface == .flat, let flatFillsVertexFunction, let flatFillsFragmentFunction {
            pipelineDescriptor.vertexFunction = flatFillsVertexFunction
            pipelineDescriptor.fragmentFunction = flatFillsFragmentFunction
            self.flatFillsPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
            self.flatOpaquePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            // The exact rank depth variants, the same three states over the
            // exact-depth fragment entry.
            pipelineDescriptor.vertexFunction = flatExactVertexFunction
            pipelineDescriptor.fragmentFunction = flatExactFragmentFunction
            self.flatExactPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.vertexFunction = flatExactFillsVertexFunction
            pipelineDescriptor.fragmentFunction = flatExactFillsFragmentFunction
            self.flatExactFillsPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
            self.flatExactOpaquePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            // The road sheet: the line-fields vertex stage under the two
            // sheet fragment entries.
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = flatRoadSheetColorFragmentFunction
            self.flatRoadSheetColorPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.fragmentFunction = flatRoadSheetDepthFragmentFunction
            pipelineDescriptor.colorAttachments[0].writeMask = []
            self.flatRoadSheetDepthPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.colorAttachments[0].writeMask = .all
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
        } else {
            self.flatRoadSheetDepthPipelineState = nil
            self.flatRoadSheetColorPipelineState = nil
            self.flatFillsPipelineState = nil
            self.flatOpaquePipelineState = nil
            self.flatExactPipelineState = nil
            self.flatExactFillsPipelineState = nil
            self.flatExactOpaquePipelineState = nil
        }
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    /// The flat line-fields pipeline (ribbons, road buckets, bridge
    /// overlay), with the exact rank depth when asked; the line-fields
    /// pipeline itself when the exact variant is absent.
    func selectFlatLinesPipeline(renderEncoder: MTLRenderCommandEncoder, exactRankDepth: Bool) {
        if exactRankDepth, let flatExactPipelineState {
            renderEncoder.setRenderPipelineState(flatExactPipelineState)
            return
        }
        selectPipeline(renderEncoder: renderEncoder)
    }

    /// The road sheet's stage pipeline; false when the pipeline has none (a
    /// sphere pipeline), and the caller draws the roads the plain way.
    @discardableResult
    func selectFlatRoadSheetPipeline(renderEncoder: MTLRenderCommandEncoder, stage: RoadSheetDepth.Stage) -> Bool {
        let state: MTLRenderPipelineState?
        switch stage {
        case .depth: state = flatRoadSheetDepthPipelineState
        case .color: state = flatRoadSheetColorPipelineState
        }
        guard let state else { return false }
        renderEncoder.setRenderPipelineState(state)
        return true
    }

    /// The flat translucent fills variant (no line fields); falls back to
    /// the line-fields pipeline when absent.
    func selectFlatFillsPipeline(renderEncoder: MTLRenderCommandEncoder, exactRankDepth: Bool = false) {
        if exactRankDepth, let flatExactFillsPipelineState {
            renderEncoder.setRenderPipelineState(flatExactFillsPipelineState)
            return
        }
        if let flatFillsPipelineState {
            renderEncoder.setRenderPipelineState(flatFillsPipelineState)
            return
        }
        selectPipeline(renderEncoder: renderEncoder)
    }

    /// The flat opaque ground variant (no line fields, blending off); falls
    /// back to the blended pipeline when absent.
    func selectFlatOpaquePipeline(renderEncoder: MTLRenderCommandEncoder, exactRankDepth: Bool = false) {
        if exactRankDepth, let flatExactOpaquePipelineState {
            renderEncoder.setRenderPipelineState(flatExactOpaquePipelineState)
            return
        }
        if let flatOpaquePipelineState {
            renderEncoder.setRenderPipelineState(flatOpaquePipelineState)
            return
        }
        selectPipeline(renderEncoder: renderEncoder)
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
