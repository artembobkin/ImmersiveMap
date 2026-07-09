// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

enum RenderPassName: String, CaseIterable {
    case buildingWinner
    case world
    case postProcessing
    case overlay
}

protocol RenderPassDescriptorProvider: AnyObject {
    func makeRenderPassDescriptor(frameContext: FrameContext,
                                  attachments: FrameAttachmentStore,
                                  drawable: CAMetalDrawable?) -> MTLRenderPassDescriptor?
}

struct RenderPassNode {
    let name: RenderPassName
    let descriptorProvider: any RenderPassDescriptorProvider
    let layers: [RenderLayer]
}
