// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TilePointScreenCompute.swift
//  ImmersiveMap
//

import CoreGraphics
import Metal
import simd

/// Shared point-to-screen compute pipelines: one set of PSOs for all
/// `TilePointScreenCompute` instances in a frame, so the combined encoder does
/// not rebind an identical pipeline state between dispatches of different buffer owners.
final class TilePointScreenPipelines {
    let flat: MTLComputePipelineState
    let globe: MTLComputePipelineState

    init(metalDevice: MTLDevice, library: MTLLibrary) {
        let flatKernel = library.makeFunction(name: "tilePointToScreenFlatKernel")
        let globeKernel = library.makeFunction(name: "tilePointToScreenGlobeKernel")
        self.flat = try! metalDevice.makeComputePipelineState(function: flatKernel!)
        self.globe = try! metalDevice.makeComputePipelineState(function: globeKernel!)
    }
}

final class TilePointScreenCompute {
    private let pipelines: TilePointScreenPipelines
    private let inputBufferStore: DynamicMetalBuffer<TilePointInput>
    private let tileSlotVisibleTileIndicesBufferStore: DynamicMetalBuffer<UInt32>
    private let outputBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>

    private(set) var inputBuffer: MTLBuffer
    private(set) var tileSlotVisibleTileIndicesBuffer: MTLBuffer

    init(metalDevice: MTLDevice, pipelines: TilePointScreenPipelines) {
        self.pipelines = pipelines
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

    /// Label of the shared compute encoder into which the frame encodes all
    /// point-to-screen dispatches (base labels + road records).
    static func passLabel(for frameContext: FrameContext) -> String {
        switch frameContext.screenSpaceProjectionMode {
        case .flat:
            return "ScreenCompute.TilePointToScreen.Flat [tilePointToScreenFlatKernel]"
        case .globe:
            return "ScreenCompute.TilePointToScreen.Globe [tilePointToScreenGlobeKernel]"
        }
    }

    /// Binds the per-frame constant state of the combined pass: PSO, camera,
    /// screen params and (for flat) the tile-origins buffer. Dispatches after
    /// this attach only their own buffers. Returns false if the pass is
    /// impossible (flat mode without an origin buffer).
    static func beginPass(encoder: MTLComputeCommandEncoder,
                          frameContext: FrameContext,
                          pipelines: TilePointScreenPipelines,
                          tileOriginDataBuffer: MTLBuffer?) -> Bool {
        var camera = frameContext.cameraUniform
        var screenParams = ScreenParams(viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width),
                                                                   Float(frameContext.drawSize.height)),
                                        outputPixels: 1)

        switch frameContext.screenSpaceProjectionMode {
        case .flat:
            guard let tileOriginDataBuffer else {
                return false
            }
            encoder.setComputePipelineState(pipelines.flat)
            encoder.setBuffer(tileOriginDataBuffer, offset: 0, index: 2)
            encoder.setBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 4)
            encoder.setBytes(&screenParams, length: MemoryLayout<ScreenParams>.stride, index: 5)
        case .globe:
            var globe = frameContext.globeRenderUniform
            encoder.setComputePipelineState(pipelines.globe)
            encoder.setBytes(&camera, length: MemoryLayout<CameraUniform>.stride, index: 2)
            encoder.setBytes(&globe, length: MemoryLayout<GlobeUniform>.stride, index: 3)
            encoder.setBytes(&screenParams, length: MemoryLayout<ScreenParams>.stride, index: 4)
        }
        return true
    }

    func encodeDispatch(encoder: MTLComputeCommandEncoder,
                        frameContext: FrameContext,
                        pointCount: Int) {
        encodeDispatch(encoder: encoder,
                       frameContext: frameContext,
                       pointCount: pointCount,
                       inputBuffer: inputBuffer,
                       tileSlotVisibleTileIndicesBuffer: tileSlotVisibleTileIndicesBuffer,
                       outputBuffer: outputBuffer(slot: frameContext.frameSlotIndex, count: pointCount))
    }

    // Encodes one dispatch into the pass started by `beginPass`: only the
    // per-record buffers and count; the frame constants are already bound.
    func encodeDispatch(encoder: MTLComputeCommandEncoder,
                        frameContext: FrameContext,
                        pointCount: Int,
                        inputBuffer: MTLBuffer,
                        tileSlotVisibleTileIndicesBuffer: MTLBuffer,
                        outputBuffer: MTLBuffer) {
        guard pointCount > 0 else {
            return
        }
        var count = UInt32(pointCount)

        switch frameContext.screenSpaceProjectionMode {
        case .flat:
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(tileSlotVisibleTileIndicesBuffer, offset: 0, index: 1)
            encoder.setBuffer(outputBuffer, offset: 0, index: 3)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 6)
            dispatch(pointCount: pointCount, encoder: encoder, pipelineState: pipelines.flat)
        case .globe:
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 5)
            dispatch(pointCount: pointCount, encoder: encoder, pipelineState: pipelines.globe)
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
