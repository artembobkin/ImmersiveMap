// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  MetalDebugComputePass.swift
//  ImmersiveMap
//

import Metal

enum MetalDebugComputePass {
    static func begin(commandBuffer: MTLCommandBuffer, label: String) -> MTLComputeCommandEncoder? {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        #if DEBUG
        commandBuffer.pushDebugGroup(label)
        encoder.label = label
        encoder.insertDebugSignpost(label)
        #endif
        return encoder
    }

    static func end(commandBuffer: MTLCommandBuffer, encoder: MTLComputeCommandEncoder) {
        encoder.endEncoding()
        #if DEBUG
        commandBuffer.popDebugGroup()
        #endif
    }
}
