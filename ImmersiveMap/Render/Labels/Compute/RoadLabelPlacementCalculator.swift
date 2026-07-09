// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class RoadLabelPlacementCalculator {
    private let pipeline: RoadLabelPlacementPipeline

    init(pipeline: RoadLabelPlacementPipeline) {
        self.pipeline = pipeline
    }

    func run(commandBuffer: MTLCommandBuffer,
             pathPointsBuffer: MTLBuffer,
             pathRangesBuffer: MTLBuffer,
             anchorsBuffer: MTLBuffer,
             glyphInputsBuffer: MTLBuffer,
             placementsBuffer: MTLBuffer,
             screenPointsBuffer: MTLBuffer,
             collisionInputsBuffer: MTLBuffer,
             collisionAabbBuffer: MTLBuffer,
             glyphCount: Int) {
        guard glyphCount > 0 else {
            return
        }
        let passLabel = "ScreenCompute.RoadLabelPlacement [roadLabelPlacementKernel]"
        guard let encoder = MetalDebugComputePass.begin(commandBuffer: commandBuffer, label: passLabel) else {
            return
        }
        defer {
            MetalDebugComputePass.end(commandBuffer: commandBuffer, encoder: encoder)
        }

        pipeline.encode(encoder: encoder)
        var count = UInt32(glyphCount)

        encoder.setBuffer(pathPointsBuffer, offset: 0, index: 0)
        encoder.setBuffer(pathRangesBuffer, offset: 0, index: 1)
        encoder.setBuffer(anchorsBuffer, offset: 0, index: 2)
        encoder.setBuffer(glyphInputsBuffer, offset: 0, index: 3)
        encoder.setBuffer(placementsBuffer, offset: 0, index: 4)
        encoder.setBuffer(screenPointsBuffer, offset: 0, index: 5)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 6)
        encoder.setBuffer(collisionInputsBuffer, offset: 0, index: 7)
        encoder.setBuffer(collisionAabbBuffer, offset: 0, index: 8)

        let threadsPerThreadgroup = MTLSize(
            width: max(1, pipeline.pipelineState.threadExecutionWidth),
            height: 1,
            depth: 1
        )
        let threadgroupsPerGrid = MTLSize(
            width: (glyphCount + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
