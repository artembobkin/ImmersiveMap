// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  RenderResourceRegistry.swift
//  ImmersiveMap
//

import Foundation
import Metal

final class RenderResourceRegistry {
    private(set) var frameIndex: UInt64 = 0
    private var buffers: [RenderResourceName: MTLBuffer] = [:]
    private var textures: [RenderResourceName: MTLTexture] = [:]
    private var pipelines: [RenderResourceName: MTLRenderPipelineState] = [:]

    func beginFrame(frameIndex: UInt64) {
        self.frameIndex = frameIndex
        buffers.removeAll(keepingCapacity: true)
        textures.removeAll(keepingCapacity: true)
        pipelines.removeAll(keepingCapacity: true)
    }

    func setBuffer(_ buffer: MTLBuffer, named name: RenderResourceName) {
        if buffer.label == nil {
            buffer.label = name.rawValue
        }
        buffers[name] = buffer
    }

    func setTexture(_ texture: MTLTexture, named name: RenderResourceName) {
        if texture.label == nil {
            texture.label = name.rawValue
        }
        textures[name] = texture
    }

    func setPipeline(_ pipeline: MTLRenderPipelineState, named name: RenderResourceName) {
        pipelines[name] = pipeline
    }

    func buffer(named name: RenderResourceName) -> MTLBuffer? {
        buffers[name]
    }

    func texture(named name: RenderResourceName) -> MTLTexture? {
        textures[name]
    }

    func pipeline(named name: RenderResourceName) -> MTLRenderPipelineState? {
        pipelines[name]
    }

    var counts: (buffers: Int, textures: Int, pipelines: Int) {
        (buffers.count, textures.count, pipelines.count)
    }
}
