// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RenderSubsystemRegistry.swift
//  ImmersiveMap
//

import Metal

final class RenderSubsystemRegistry {
    private let subsystems: [any RenderSubsystem]

    init(subsystems: [any RenderSubsystem]) {
        self.subsystems = subsystems
    }

    var orderedSubsystemNames: [String] {
        subsystems.map(\.name)
    }

    func update(frameContext: FrameContext) {
        for subsystem in subsystems {
            subsystem.update(frameContext: frameContext)
        }
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry) {
        for subsystem in subsystems {
            subsystem.prepareGPU(frameContext: frameContext, resourceRegistry: resourceRegistry)
        }
    }

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        for subsystem in subsystems {
            subsystem.encode(layer: layer, encoder: encoder, frameContext: frameContext)
        }
    }

    func frameCommitted() {
        for subsystem in subsystems {
            subsystem.frameCommitted()
        }
    }

    func handleMemoryWarning() {
        for subsystem in subsystems {
            subsystem.handleMemoryWarning()
        }
    }

    func evict() {
        for subsystem in subsystems {
            subsystem.evict()
        }
    }
}
