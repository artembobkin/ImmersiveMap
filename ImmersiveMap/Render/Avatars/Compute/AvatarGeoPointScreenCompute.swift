// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

final class AvatarGeoPointScreenBuffers {
    private let inputBufferStore: DynamicMetalBuffer<AvatarGeoInput>
    private let worldInputBufferStore: DynamicMetalBuffer<SIMD2<Float>>
    private let outputBufferStore: DynamicMetalBuffer<ScreenPointOutput>
    fileprivate var inputBuffer: MTLBuffer { inputBufferStore.buffer }
    fileprivate var worldInputBuffer: MTLBuffer { worldInputBufferStore.buffer }
    fileprivate var outputBuffer: MTLBuffer { outputBufferStore.buffer }
    private(set) var pointsCount: Int = 0

    init(metalDevice: MTLDevice) {
        self.inputBufferStore = DynamicMetalBuffer(metalDevice: metalDevice)
        self.worldInputBufferStore = DynamicMetalBuffer(metalDevice: metalDevice)
        self.outputBufferStore = DynamicMetalBuffer(metalDevice: metalDevice)
    }

    private func ensureBuffersCapacity(count: Int) {
        let itemCount = max(1, count)
        _ = inputBufferStore.ensureCapacity(count: itemCount)
        _ = worldInputBufferStore.ensureCapacity(count: itemCount)
        _ = outputBufferStore.ensureCapacity(count: itemCount)
    }

    func copyDataToBuffer(inputs: [AvatarGeoInput]) {
        ensureBuffersCapacity(count: inputs.count)
        if inputs.isEmpty {
            pointsCount = 0
            return
        }
        let inputBytes = inputs.count * MemoryLayout<AvatarGeoInput>.stride
        inputs.withUnsafeBytes { bytes in
            inputBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: inputBytes)
        }
        pointsCount = inputs.count
    }

    func copyWorldDataToBuffer(inputs: [SIMD2<Float>]) {
        ensureBuffersCapacity(count: inputs.count)
        if inputs.isEmpty {
            pointsCount = 0
            return
        }
        let inputBytes = inputs.count * MemoryLayout<SIMD2<Float>>.stride
        inputs.withUnsafeBytes { bytes in
            worldInputBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: inputBytes)
        }
        pointsCount = inputs.count
    }
}

final class AvatarGeoPointGlobeAndTransitionComputePipeline {
    let pipelineState: MTLComputePipelineState

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        let kernel = library.makeFunction(name: "avatarGeoPointToScreenGlobeAndTransitionKernel")
        self.pipelineState = try! metalDevice.makeComputePipelineState(function: kernel!)
    }

    func encode(encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipelineState)
    }
}

final class AvatarWorldPointFlatComputePipeline {
    let pipelineState: MTLComputePipelineState

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        let kernel = library.makeFunction(name: "avatarWorldPointToScreenFlatKernel")
        self.pipelineState = try! metalDevice.makeComputePipelineState(function: kernel!)
    }

    func encode(encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipelineState)
    }
}

final class AvatarGeoPointScreenCompute {
    private let buffers: AvatarGeoPointScreenBuffers
    private let globeAndTransitionPipeline: AvatarGeoPointGlobeAndTransitionComputePipeline
    private let flatPipeline: AvatarWorldPointFlatComputePipeline

    var inputBuffer: MTLBuffer { buffers.inputBuffer }
    var worldInputBuffer: MTLBuffer { buffers.worldInputBuffer }
    var outputBuffer: MTLBuffer { buffers.outputBuffer }
    var pointsCount: Int { buffers.pointsCount }

    init(globePipeline: AvatarGeoPointGlobeAndTransitionComputePipeline,
         worldPipeline: AvatarWorldPointFlatComputePipeline,
         metalDevice: MTLDevice) {
        self.globeAndTransitionPipeline = globePipeline
        self.flatPipeline = worldPipeline
        self.buffers = AvatarGeoPointScreenBuffers(metalDevice: metalDevice)
    }

    func copyDataToBuffer(inputs: [AvatarGeoInput]) {
        buffers.copyDataToBuffer(inputs: inputs)
    }

    func copyWorldDataToBuffer(inputs: [SIMD2<Float>]) {
        buffers.copyWorldDataToBuffer(inputs: inputs)
    }

    func runGlobeAndTransition(drawSize: CGSize,
                               cameraUniform: CameraUniform,
                               globe: GlobeUniform,
                               commandBuffer: MTLCommandBuffer) {
        guard buffers.pointsCount > 0 else { return }
        let passLabel = "Avatars.GeoToScreen.GlobeAndTransition [avatarGeoPointToScreenGlobeAndTransitionKernel]"
        guard let encoder = MetalDebugComputePass.begin(commandBuffer: commandBuffer, label: passLabel) else { return }
        defer {
            MetalDebugComputePass.end(commandBuffer: commandBuffer, encoder: encoder)
        }
        globeAndTransitionPipeline.encode(encoder: encoder)

        var screenParams = ScreenParams(viewportSize: SIMD2<Float>(Float(drawSize.width), Float(drawSize.height)),
                                        outputPixels: 1)
        var camera = cameraUniform
        var globeValue = globe
        var count = UInt32(buffers.pointsCount)

        encoder.setBuffer(buffers.inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(buffers.outputBuffer, offset: 0, index: 1)
        encoder.setBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 2)
        encoder.setBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 3)
        encoder.setBytes(&screenParams, length: MemoryLayout<ScreenParams>.stride, index: 4)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 5)

        let threadsPerThreadgroup = MTLSize(width: max(1, globeAndTransitionPipeline.pipelineState.threadExecutionWidth),
                                            height: 1,
                                            depth: 1)
        let threadgroupsPerGrid = MTLSize(width: (buffers.pointsCount + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                          height: 1,
                                          depth: 1)
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    func runFlat(drawSize: CGSize,
                 cameraUniform: CameraUniform,
                 commandBuffer: MTLCommandBuffer) {
        guard buffers.pointsCount > 0 else { return }
        let passLabel = "Avatars.GeoToScreen.Flat [avatarWorldPointToScreenFlatKernel]"
        guard let encoder = MetalDebugComputePass.begin(commandBuffer: commandBuffer, label: passLabel) else { return }
        defer {
            MetalDebugComputePass.end(commandBuffer: commandBuffer, encoder: encoder)
        }
        flatPipeline.encode(encoder: encoder)

        var screenParams = ScreenParams(viewportSize: SIMD2<Float>(Float(drawSize.width), Float(drawSize.height)),
                                        outputPixels: 1)
        var camera = cameraUniform
        var count = UInt32(buffers.pointsCount)

        encoder.setBuffer(buffers.worldInputBuffer, offset: 0, index: 0)
        encoder.setBuffer(buffers.outputBuffer, offset: 0, index: 1)
        encoder.setBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 2)
        encoder.setBytes(&screenParams, length: MemoryLayout<ScreenParams>.stride, index: 3)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 4)

        let threadsPerThreadgroup = MTLSize(width: max(1, flatPipeline.pipelineState.threadExecutionWidth),
                                            height: 1,
                                            depth: 1)
        let threadgroupsPerGrid = MTLSize(width: (buffers.pointsCount + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                          height: 1,
                                          depth: 1)
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
