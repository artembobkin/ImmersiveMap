// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

/// Encodes the render passes of one frame: acquires the render target, prepares attachments and the pass plan, and invokes subsystem encoders.
final class RenderFramePassEncoder {
    private let attachments: FrameAttachmentStore
    private let passGraph = RenderPassGraph()
    private let renderGraph: RenderGraph

    init(attachments: FrameAttachmentStore,
         renderGraph: RenderGraph) {
        self.attachments = attachments
        self.renderGraph = renderGraph
    }

    func encode(frameContext: FrameContext,
                acquireTarget: () -> FrameRenderTarget?,
                settings: ImmersiveMapSettings) -> FrameRenderTarget? {
        guard let commandBuffer = frameContext.commandBuffer else {
            frameContext.services.diagnostics.recordSkipReason(.missingCommandBuffer)
            return nil
        }

        // Acquired here — after the command-buffer guard — to preserve the live
        // path's drawable-acquisition timing exactly.
        guard let target = acquireTarget() else {
            frameContext.services.diagnostics.recordSkipReason(.missingDrawable)
            return nil
        }

        recordDisabledLayerSkips(settings: settings,
                                 frameContext: frameContext)

        let passNodes = passGraph.plan(frameContext: frameContext,
                                       settings: settings,
                                       attachments: attachments,
                                       target: target,
                                       renderGraph: renderGraph)

        for passNode in passNodes {
            guard let descriptor = passNode.descriptorProvider.makeRenderPassDescriptor(frameContext: frameContext,
                                                                                       attachments: attachments,
                                                                                       target: target),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                continue
            }

            let passStart = CACurrentMediaTime()
            for layer in passNode.layers {
                let layerStart = CACurrentMediaTime()
                renderGraph.encode(layer: layer,
                                   encoder: renderEncoder,
                                   frameContext: frameContext)
                frameContext.diagnostics.recordLayer(layer,
                                                     duration: CACurrentMediaTime() - layerStart)
            }
            renderEncoder.endEncoding()
            frameContext.diagnostics.recordMetalPass(passNode.name,
                                                     duration: CACurrentMediaTime() - passStart)
        }

        return target
    }

    private func recordDisabledLayerSkips(settings: ImmersiveMapSettings,
                                          frameContext: FrameContext) {
        let passAvailability = renderGraph.passAvailability(settings: settings,
                                                            renderSurfaceMode: frameContext.renderSurfaceMode)
        let layerPlan = RenderLayerPlanner.plan(availability: passAvailability)
        for planItem in layerPlan where planItem.enabled == false {
            if let reason = planItem.skipReason {
                frameContext.services.diagnostics.recordSkipReason(reason)
            }
        }
    }
}
