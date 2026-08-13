// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class RoadLabelPlacementCalculator {
    /// Buffers of one tile record for a glyph-placement dispatch.
    struct RecordDispatch {
        let pathPointsBuffer: MTLBuffer
        let pathRangesBuffer: MTLBuffer
        let anchorsBuffer: MTLBuffer
        let glyphInputsBuffer: MTLBuffer
        let placementsBuffer: MTLBuffer
        let screenPointsBuffer: MTLBuffer
        let collisionInputsBuffer: MTLBuffer
        let collisionAabbBuffer: MTLBuffer
        let glyphCount: Int
    }

    private let pipeline: RoadLabelPlacementPipeline

    init(pipeline: RoadLabelPlacementPipeline) {
        self.pipeline = pipeline
    }

    // All records of the frame are encoded into one compute encoder: the pipeline
    // state is set once, dispatches differ only in buffers and glyph count.
    func run(commandBuffer: MTLCommandBuffer,
             screenScale: ScreenScale,
             dispatches: [RecordDispatch]) {
        let activeDispatches = dispatches.filter { $0.glyphCount > 0 }
        guard activeDispatches.isEmpty == false else {
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
        let threadsPerThreadgroup = MTLSize(
            width: max(1, pipeline.pipelineState.threadExecutionWidth),
            height: 1,
            depth: 1
        )
        // Glyph advances and collision boxes arrive in layout points, the
        // projected path they are placed along is in device pixels: the kernel
        // converts the former with this.
        var pixelsPerPoint = screenScale.pixelsPerPoint
        encoder.setBytes(&pixelsPerPoint, length: MemoryLayout<Float>.stride, index: 9)

        for recordDispatch in activeDispatches {
            var count = UInt32(recordDispatch.glyphCount)

            encoder.setBuffer(recordDispatch.pathPointsBuffer, offset: 0, index: 0)
            encoder.setBuffer(recordDispatch.pathRangesBuffer, offset: 0, index: 1)
            encoder.setBuffer(recordDispatch.anchorsBuffer, offset: 0, index: 2)
            encoder.setBuffer(recordDispatch.glyphInputsBuffer, offset: 0, index: 3)
            encoder.setBuffer(recordDispatch.placementsBuffer, offset: 0, index: 4)
            encoder.setBuffer(recordDispatch.screenPointsBuffer, offset: 0, index: 5)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 6)
            encoder.setBuffer(recordDispatch.collisionInputsBuffer, offset: 0, index: 7)
            encoder.setBuffer(recordDispatch.collisionAabbBuffer, offset: 0, index: 8)

            let threadgroupsPerGrid = MTLSize(
                width: (recordDispatch.glyphCount + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                height: 1,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        }
    }
}
