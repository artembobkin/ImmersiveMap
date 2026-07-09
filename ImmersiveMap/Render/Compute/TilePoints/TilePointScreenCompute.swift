// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TilePointScreenCompute.swift
//  ImmersiveMap
//

import CoreGraphics
import Metal
import simd

final class TilePointScreenCompute {
    private let flatPipelineState: MTLComputePipelineState
    private let globePipelineState: MTLComputePipelineState
    private let inputBufferStore: DynamicMetalBuffer<TilePointInput>
    private let tileSlotVisibleTileIndicesBufferStore: DynamicMetalBuffer<UInt32>
    private let outputBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>

    private(set) var inputBuffer: MTLBuffer
    private(set) var tileSlotVisibleTileIndicesBuffer: MTLBuffer

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        let flatKernel = library.makeFunction(name: "tilePointToScreenFlatKernel")
        let globeKernel = library.makeFunction(name: "tilePointToScreenGlobeKernel")
        self.flatPipelineState = try! metalDevice.makeComputePipelineState(function: flatKernel!)
        self.globePipelineState = try! metalDevice.makeComputePipelineState(function: globeKernel!)
        self.inputBufferStore = DynamicMetalBuffer(metalDevice: metalDevice, options: [.storageModeShared])
        self.tileSlotVisibleTileIndicesBufferStore = DynamicMetalBuffer(metalDevice: metalDevice, options: [.storageModeShared])
        self.outputBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                options: [.storageModeShared])
        self.inputBuffer = inputBufferStore.buffer
        self.tileSlotVisibleTileIndicesBuffer = tileSlotVisibleTileIndicesBufferStore.buffer
    }

    func uploadInputs(_ inputs: [TilePointInput]) {
        inputBuffer = inputBufferStore.ensureCapacity(count: max(1, inputs.count))
        guard inputs.isEmpty == false else {
            return
        }
        let byteCount = inputs.count * MemoryLayout<TilePointInput>.stride
        inputs.withUnsafeBytes { bytes in
            inputBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
        }
    }

    func uploadTileSlotVisibleTileIndices(_ indices: [UInt32]) {
        tileSlotVisibleTileIndicesBuffer = tileSlotVisibleTileIndicesBufferStore.ensureCapacity(count: max(1, indices.count))
        guard indices.isEmpty == false else {
            return
        }
        let byteCount = indices.count * MemoryLayout<UInt32>.stride
        indices.withUnsafeBytes { bytes in
            tileSlotVisibleTileIndicesBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
        }
    }

    func outputBuffer(slot: Int, count: Int) -> MTLBuffer {
        outputBufferStore.ensureCapacity(slot: slot, count: max(1, count))
    }

    func run(frameContext: FrameContext,
             pointCount: Int,
             tileOriginDataBuffer: MTLBuffer?) {
        run(frameContext: frameContext,
            pointCount: pointCount,
            inputBuffer: inputBuffer,
            tileSlotVisibleTileIndicesBuffer: tileSlotVisibleTileIndicesBuffer,
            tileOriginDataBuffer: tileOriginDataBuffer,
            outputBuffer: outputBuffer(slot: frameContext.frameSlotIndex, count: pointCount))
    }

    func run(frameContext: FrameContext,
             pointCount: Int,
             inputBuffer: MTLBuffer,
             tileSlotVisibleTileIndicesBuffer: MTLBuffer,
             tileOriginDataBuffer: MTLBuffer?,
             outputBuffer: MTLBuffer) {
        guard pointCount > 0,
              let commandBuffer = frameContext.commandBuffer else {
            return
        }

        let label: String
        let pipelineState: MTLComputePipelineState
        let screenParams = ScreenParams(viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                                   Float(frameContext.drawSize.height)),
                                        outputPixels: 1)
        var count = UInt32(pointCount)
        var camera = frameContext.cameraUniform

        switch frameContext.screenSpaceProjectionMode {
        case .flat:
            guard let tileOriginDataBuffer else {
                return
            }
            label = "ScreenCompute.TilePointToScreen.Flat [tilePointToScreenFlatKernel]"
            pipelineState = flatPipelineState
            guard let encoder = MetalDebugComputePass.begin(commandBuffer: commandBuffer, label: label) else {
                return
            }
            defer {
                MetalDebugComputePass.end(commandBuffer: commandBuffer, encoder: encoder)
            }

            encoder.setComputePipelineState(pipelineState)
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(tileSlotVisibleTileIndicesBuffer, offset: 0, index: 1)
            encoder.setBuffer(tileOriginDataBuffer, offset: 0, index: 2)
            encoder.setBuffer(outputBuffer, offset: 0, index: 3)
            encoder.setBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 4)
            var screenParamsValue = screenParams
            encoder.setBytes(&screenParamsValue, length: MemoryLayout<ScreenParams>.stride, index: 5)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 6)
            dispatch(pointCount: pointCount, encoder: encoder, pipelineState: pipelineState)
        case .globe:
            label = "ScreenCompute.TilePointToScreen.Globe [tilePointToScreenGlobeKernel]"
            pipelineState = globePipelineState
            guard let encoder = MetalDebugComputePass.begin(commandBuffer: commandBuffer, label: label) else {
                return
            }
            defer {
                MetalDebugComputePass.end(commandBuffer: commandBuffer, encoder: encoder)
            }

            var globe = frameContext.globeRenderUniform
            encoder.setComputePipelineState(pipelineState)
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.setBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 2)
            encoder.setBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 3)
            var screenParamsValue = screenParams
            encoder.setBytes(&screenParamsValue, length: MemoryLayout<ScreenParams>.stride, index: 4)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 5)
            dispatch(pointCount: pointCount, encoder: encoder, pipelineState: pipelineState)
        }
    }

    private func dispatch(pointCount: Int,
                          encoder: MTLComputeCommandEncoder,
                          pipelineState: MTLComputePipelineState) {
        let threadsPerThreadgroup = MTLSize(width: max(1, pipelineState.threadExecutionWidth),
                                            height: 1,
                                            depth: 1)
        let threadgroupsPerGrid = MTLSize(width: (pointCount + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
                                          height: 1,
                                          depth: 1)
        encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
