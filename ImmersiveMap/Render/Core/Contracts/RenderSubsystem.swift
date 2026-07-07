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
    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry)
    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext)
    /// Вызывается после `commit()` command buffer кадра: только в этот момент
    /// GPU-работа, закодированная в `prepareGPU`, гарантированно будет выполнена.
    /// Кадр может быть отброшен после `prepareGPU` (нет drawable) - staged-состояние,
    /// зависящее от закодированной GPU-работы, нельзя фиксировать раньше этого хука.
    func frameCommitted()
    func handleMemoryWarning()
    func evict()
}

extension RenderSubsystem {
    func frameCommitted() {}
}
