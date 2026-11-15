// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

struct RenderMetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let renderSampleCount: Int

    func makeCommandBuffer() -> MTLCommandBuffer? {
        commandQueue.makeCommandBuffer()
    }
}
