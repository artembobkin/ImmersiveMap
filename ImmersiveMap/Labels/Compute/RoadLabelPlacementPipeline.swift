// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class RoadLabelPlacementPipeline {
    let pipelineState: MTLComputePipelineState

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        let kernel = library.makeFunction(name: "roadLabelPlacementKernel")
        self.pipelineState = try! metalDevice.makeComputePipelineState(function: kernel!)
    }

    func encode(encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipelineState)
    }
}
