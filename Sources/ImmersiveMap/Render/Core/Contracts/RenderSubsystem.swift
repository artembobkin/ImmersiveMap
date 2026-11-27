// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  RenderSubsystem.swift
//  ImmersiveMap
//

import Metal

protocol RenderSubsystem: AnyObject {
    var name: String { get }

    func update(frameContext: FrameContext)
    func prepareGPU(frameContext: FrameContext)
    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext)
    /// Called after the frame's command buffer `commit()`: only at this point is
    /// the GPU work encoded in `prepareGPU` guaranteed to execute.
    /// A frame may be dropped after `prepareGPU` (no drawable) - staged state that
    /// depends on the encoded GPU work must not be committed before this hook.
    func frameCommitted()
    func handleMemoryWarning()
}

/// A subsystem implements the steps it has work in. The rest do nothing.
extension RenderSubsystem {
    func update(frameContext _: FrameContext) {}
    func prepareGPU(frameContext _: FrameContext) {}
    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}
    func frameCommitted() {}
    func handleMemoryWarning() {}
}
