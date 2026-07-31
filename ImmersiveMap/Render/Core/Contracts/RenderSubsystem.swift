// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderSubsystem.swift
//  ImmersiveMap
//

import Metal

protocol RenderSubsystem: AnyObject {
    var name: String { get }

    func update(frameContext: FrameContext)
    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry)
    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext)
    /// Called after the frame's command buffer `commit()`: only at this point is
    /// the GPU work encoded in `prepareGPU` guaranteed to execute.
    /// A frame may be dropped after `prepareGPU` (no drawable) - staged state that
    /// depends on the encoded GPU work must not be committed before this hook.
    func frameCommitted()
    func handleMemoryWarning()
    func evict()
}

extension RenderSubsystem {
    func frameCommitted() {}
}
