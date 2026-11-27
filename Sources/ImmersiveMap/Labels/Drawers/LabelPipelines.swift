// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// The pipelines the labels draw by (`RendererLabelDrawer`): glyph quads and
/// sprites anchored to a label's screen position (`LabelVertex`). One set
/// for the process. The labels draw in passes of one sample.
final class LabelPipelines: SharedGPUResources {
    /// The names: the base labels' text.
    let label: MTLRenderPipelineState
    /// The road names, which read the world's depth.
    let roadLabel: MTLRenderPipelineState
    /// The POI plates and their icons.
    let poiIcon: MTLRenderPipelineState
    /// The route sign plates: the POI quad's vertex stage and the plate's
    /// distance field (RouteShield.metal).
    let routeShield: MTLRenderPipelineState

    init(device: MTLDevice, library: MTLLibrary) {
        guard let labelVertexFn = library.makeFunction(name: "labelTextVertex"),
              let roadLabelVertexFn = library.makeFunction(name: "roadLabelTextVertex"),
              let poiIconVertexFn = library.makeFunction(name: "poiSpriteVertex"),
              let poiIconFragmentFn = library.makeFunction(name: "poiSpriteFragment"),
              let routeShieldFragmentFn = library.makeFunction(name: "routeShieldFragment"),
              let fragmentFn = library.makeFunction(name: "textFragment"),
              let roadFragmentFn = library.makeFunction(name: "roadTextFragment") else {
            fatalError("Functions not found")
        }

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.position) ?? 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.uv) ?? 0
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .int
        vertexDescriptor.attributes[2].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.labelIndex) ?? 0
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float2
        vertexDescriptor.attributes[3].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.spriteUV) ?? 0
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<LabelVertex>.stride

        func state(_ vertexFunction: MTLFunction, _ fragmentFunction: MTLFunction) throws -> MTLRenderPipelineState {
            try TextPipeline.makePipelineState(device: device,
                                               vertexFunction: vertexFunction,
                                               vertexDescriptor: vertexDescriptor,
                                               fragmentFunction: fragmentFunction)
        }
        do {
            label = try state(labelVertexFn, fragmentFn)
            roadLabel = try state(roadLabelVertexFn, roadFragmentFn)
            poiIcon = try state(poiIconVertexFn, poiIconFragmentFn)
            routeShield = try state(poiIconVertexFn, routeShieldFragmentFn)
        } catch {
            fatalError("Pipeline creation failed: \(error)")
        }
    }

    static func make(_ build: SharedGPUResourceBuild) -> LabelPipelines {
        LabelPipelines(device: build.device, library: build.library)
    }
}
