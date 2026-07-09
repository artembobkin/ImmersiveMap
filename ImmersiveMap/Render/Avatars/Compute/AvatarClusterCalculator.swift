// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import CoreGraphics

final class AvatarOffsetPipeline {
    let pipelineState: MTLComputePipelineState

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        let kernel = library.makeFunction(name: "avatarOffsetKernel")
        self.pipelineState = try! metalDevice.makeComputePipelineState(function: kernel!)
    }

    func encode(encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipelineState)
    }
}

final class AvatarClusterCalculator {
    private let offsetPipeline: AvatarOffsetPipeline
    private let offsetPingBufferStore: DynamicMetalBuffer<AvatarOffset>
    private let offsetPongBufferStore: DynamicMetalBuffer<AvatarOffset>

    private var offsetPingBuffer: MTLBuffer { offsetPingBufferStore.buffer }
    private var offsetPongBuffer: MTLBuffer { offsetPongBufferStore.buffer }
    private var currentIsPing: Bool = true

    struct OffsetParams {
        var count: UInt32
        var liftPx: Float
        var smoothing: Float
        var _padding: Float = 0.0
    }

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        self.offsetPipeline = AvatarOffsetPipeline(metalDevice: metalDevice, library: library)
        self.offsetPingBufferStore = DynamicMetalBuffer(metalDevice: metalDevice)
        self.offsetPongBufferStore = DynamicMetalBuffer(metalDevice: metalDevice)
    }

    func run(avatarCount: Int,
             screenPointsBuffer: MTLBuffer,
             config: ImmersiveMapSettings.AvatarSettings,
             commandBuffer: MTLCommandBuffer) -> MTLBuffer {
        guard avatarCount > 0 else {
            return offsetPingBuffer
        }
        ensureOffsetsCapacity(avatarCount: avatarCount)

        let sizePx = Float(config.size.rawValue) * config.sizeScale
        let liftPx = max(0.0, sizePx * config.singleLiftScale)
        var params = OffsetParams(count: UInt32(avatarCount),
                                  liftPx: liftPx,
                                  smoothing: config.smoothing)

        let passLabel = "Avatars.ClusterOffset [avatarOffsetKernel]"
        guard let encoder = MetalDebugComputePass.begin(commandBuffer: commandBuffer, label: passLabel) else {
            return currentIsPing ? offsetPingBuffer : offsetPongBuffer
        }
        defer {
            MetalDebugComputePass.end(commandBuffer: commandBuffer, encoder: encoder)
        }

        offsetPipeline.encode(encoder: encoder)
        let inputOffsets = currentIsPing ? offsetPingBuffer : offsetPongBuffer
        let outputOffsets = currentIsPing ? offsetPongBuffer : offsetPingBuffer
        encoder.setBuffer(screenPointsBuffer, offset: 0, index: 0)
        encoder.setBuffer(inputOffsets, offset: 0, index: 1)
        encoder.setBuffer(outputOffsets, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<OffsetParams>.stride, index: 3)

        let threads = MTLSize(width: max(1, offsetPipeline.pipelineState.threadExecutionWidth), height: 1, depth: 1)
        let groups = MTLSize(width: (avatarCount + threads.width - 1) / threads.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)

        currentIsPing.toggle()
        return currentIsPing ? offsetPingBuffer : offsetPongBuffer
    }

    func resetOffsets(count: Int) {
        ensureOffsetsCapacity(avatarCount: count)
        let itemCount = max(1, count)
        let base = AvatarOffset(value: .zero, scale: 1.0, _padding: 0.0)
        let pingPtr = offsetPingBuffer.contents().bindMemory(to: AvatarOffset.self, capacity: itemCount)
        let pongPtr = offsetPongBuffer.contents().bindMemory(to: AvatarOffset.self, capacity: itemCount)
        for i in 0..<itemCount {
            pingPtr[i] = base
            pongPtr[i] = base
        }
        currentIsPing = true
    }

    private func ensureOffsetsCapacity(avatarCount: Int) {
        let count = max(1, avatarCount)
        _ = offsetPingBufferStore.ensureCapacity(count: count)
        _ = offsetPongBufferStore.ensureCapacity(count: count)
    }
}
