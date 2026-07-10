// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

final class RenderPassGraph {
    static func isWorldLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .starfield, .globeSurface, .globeCap, .flatMapSurface, .buildingExtrusion:
            return true
        case .buildingWinner, .postProcessing, .labels, .avatars, .debugOverlay:
            return false
        }
    }

    static func isOverlayLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .labels, .avatars, .debugOverlay:
            return true
        case .buildingWinner, .starfield, .globeSurface, .globeCap, .flatMapSurface, .buildingExtrusion,
             .postProcessing:
            return false
        }
    }

    private final class BuildingWinnerDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      drawable _: CAMetalDrawable?) -> MTLRenderPassDescriptor? {
            guard frameContext.renderSurfaceMode == .flat,
                  let winnerIDTexture = attachments.ensureBuildingWinnerIDTexture(drawSize: frameContext.drawSize),
                  let winnerDepthTexture = attachments.ensureBuildingWinnerDepthTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = winnerIDTexture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            descriptor.depthAttachment.texture = winnerDepthTexture
            descriptor.depthAttachment.loadAction = .clear
            descriptor.depthAttachment.storeAction = .dontCare
            descriptor.depthAttachment.clearDepth = 1.0
            return descriptor
        }
    }

    private final class WorldDescriptorProvider: RenderPassDescriptorProvider {
        private let clearColor: MTLClearColor
        private let depthTexture: MTLTexture?
        private let outputPlan: RenderFrameOutputPlan

        init(clearColor: MTLClearColor,
             depthTexture: MTLTexture?,
             outputPlan: RenderFrameOutputPlan) {
            self.clearColor = clearColor
            self.depthTexture = depthTexture
            self.outputPlan = outputPlan
        }

        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      drawable: CAMetalDrawable?) -> MTLRenderPassDescriptor? {
            guard let drawable else {
                return nil
            }

            let outputTexture: MTLTexture?
            switch outputPlan.worldColorDestination {
            case .drawable:
                outputTexture = drawable.texture
            case .postProcessingInput:
                outputTexture = attachments.ensurePostProcessingInputTexture(
                    drawSize: frameContext.drawSize,
                    pixelFormat: drawable.texture.pixelFormat
                )
            }
            guard let outputTexture else { return nil }

            let descriptor = MTLRenderPassDescriptor()
            if outputPlan.usesMultisampleResolve {
                guard let colorTexture = attachments.ensureColorTexture(
                    drawSize: frameContext.drawSize,
                    pixelFormat: drawable.texture.pixelFormat
                ) else {
                    return nil
                }
                descriptor.colorAttachments[0].texture = colorTexture
                descriptor.colorAttachments[0].resolveTexture = outputTexture
                descriptor.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                descriptor.colorAttachments[0].texture = outputTexture
                descriptor.colorAttachments[0].storeAction = .store
            }
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = clearColor
            if let depthTexture {
                descriptor.depthAttachment.texture = depthTexture
                descriptor.depthAttachment.loadAction = .clear
                descriptor.depthAttachment.storeAction = .dontCare
                descriptor.depthAttachment.clearDepth = 1.0
            }
            return descriptor
        }
    }

    private final class PostProcessingDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext _: FrameContext,
                                      attachments _: FrameAttachmentStore,
                                      drawable: CAMetalDrawable?) -> MTLRenderPassDescriptor? {
            guard let drawable else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            return descriptor
        }
    }

    private final class OverlayDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      drawable: CAMetalDrawable?) -> MTLRenderPassDescriptor? {
            guard let drawable,
                  let depthTexture = attachments.ensureOverlayDepthTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.depthAttachment.texture = depthTexture
            descriptor.depthAttachment.loadAction = .clear
            descriptor.depthAttachment.storeAction = .dontCare
            descriptor.depthAttachment.clearDepth = 1.0
            return descriptor
        }
    }

    func plan(frameContext: FrameContext,
              settings: ImmersiveMapSettings,
              attachments: FrameAttachmentStore,
              drawable: CAMetalDrawable,
              renderGraph: RenderGraph) -> [RenderPassNode] {
        let resourceRegistry = renderGraph.resourceRegistry
        let depthTexture = attachments.ensureDepthTexture(drawSize: frameContext.drawSize)
        if let depthTexture {
            resourceRegistry.setTexture(depthTexture, named: .depthTexture)
        }

        let clearColor = RenderFrameClearColor.make(transition: frameContext.transition,
                                                    settings: settings)
        let layerAvailability = renderGraph.passAvailability(settings: settings,
                                                             renderSurfaceMode: frameContext.renderSurfaceMode)
        let layerPlan = RenderLayerPlanner.plan(availability: layerAvailability)
            .filter(\.enabled)
            .map(\.layer)

        var nodes: [RenderPassNode] = []
        if frameContext.renderSurfaceMode == .flat,
           let winnerIDTexture = attachments.ensureBuildingWinnerIDTexture(drawSize: frameContext.drawSize),
           let winnerDepthTexture = attachments.ensureBuildingWinnerDepthTexture(drawSize: frameContext.drawSize) {
            resourceRegistry.setTexture(winnerIDTexture, named: .buildingWinnerIDTexture)
            resourceRegistry.setTexture(winnerDepthTexture, named: .buildingWinnerDepthTexture)
            nodes.append(RenderPassNode(name: .buildingWinner,
                                        descriptorProvider: BuildingWinnerDescriptorProvider(),
                                        layers: [.buildingWinner]))
        }
        let worldLayers = layerPlan.filter(Self.isWorldLayer)
        let overlayLayers = layerPlan.filter(Self.isOverlayLayer)
        let outputPlan = RenderFrameOutputPlanner.plan(
            fxaaEnabled: settings.postProcessing.fxaaEnabled,
            renderSampleCount: attachments.sampleCount
        )

        nodes.append(RenderPassNode(name: .world,
                                    descriptorProvider: WorldDescriptorProvider(clearColor: clearColor,
                                                                                depthTexture: depthTexture,
                                                                                outputPlan: outputPlan),
                                    layers: worldLayers))
        if outputPlan.includesPostProcessingPass {
            nodes.append(RenderPassNode(name: .postProcessing,
                                        descriptorProvider: PostProcessingDescriptorProvider(),
                                        layers: [.postProcessing]))
        }
        if overlayLayers.isEmpty == false {
            nodes.append(RenderPassNode(name: .overlay,
                                        descriptorProvider: OverlayDescriptorProvider(),
                                        layers: overlayLayers))
        }
        return nodes
    }
}
