// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

final class RenderPassGraph {
    static func isWorldLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .starfield, .globeSurface, .globeCap, .flatMapSurface, .buildingExtrusion:
            return true
        case .buildingImage, .postProcessing, .labels, .avatars, .debugOverlay:
            return false
        }
    }

    static func isOverlayLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .labels, .avatars, .debugOverlay:
            return true
        case .buildingImage, .starfield, .globeSurface, .globeCap, .flatMapSurface, .buildingExtrusion,
             .postProcessing:
            return false
        }
    }

    private final class BuildingImageDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target: FrameRenderTarget?) -> MTLRenderPassDescriptor? {
            guard frameContext.renderSurfaceMode == .flat,
                  let target,
                  let buildingImageTexture = attachments.ensureBuildingImageTexture(drawSize: frameContext.drawSize,
                                                                                    pixelFormat: target.texture.pixelFormat),
                  let depthTexture = attachments.ensureDepthTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            if attachments.sampleCount > 1 {
                guard let msaaColorTexture = attachments.ensureBuildingImageColorTexture(drawSize: frameContext.drawSize,
                                                                                         pixelFormat: target.texture.pixelFormat) else {
                    return nil
                }
                descriptor.colorAttachments[0].texture = msaaColorTexture
                descriptor.colorAttachments[0].resolveTexture = buildingImageTexture
                descriptor.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                descriptor.colorAttachments[0].texture = buildingImageTexture
                descriptor.colorAttachments[0].storeAction = .store
            }
            descriptor.colorAttachments[0].loadAction = .clear
            // Transparent background: after resolve the alpha holds the building
            // silhouette coverage, and the color is premultiplied by that coverage.
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            // Depth is shared with the world pass: both passes start with .clear
            // and never read previous contents, so there is no hazard between them.
            descriptor.depthAttachment.texture = depthTexture
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
                                      target: FrameRenderTarget?) -> MTLRenderPassDescriptor? {
            guard let target else {
                return nil
            }

            let outputTexture: MTLTexture?
            switch outputPlan.worldColorDestination {
            case .drawable:
                outputTexture = target.texture
            case .postProcessingInput:
                outputTexture = attachments.ensurePostProcessingInputTexture(
                    drawSize: frameContext.drawSize,
                    pixelFormat: target.texture.pixelFormat
                )
            }
            guard let outputTexture else { return nil }

            let descriptor = MTLRenderPassDescriptor()
            if outputPlan.usesMultisampleResolve {
                guard let colorTexture = attachments.ensureColorTexture(
                    drawSize: frameContext.drawSize,
                    pixelFormat: target.texture.pixelFormat
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
                                      target: FrameRenderTarget?) -> MTLRenderPassDescriptor? {
            guard let target else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target.texture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            return descriptor
        }
    }

    private final class OverlayDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target: FrameRenderTarget?) -> MTLRenderPassDescriptor? {
            guard let target,
                  let depthTexture = attachments.ensureOverlayDepthTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target.texture
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
              target: FrameRenderTarget,
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
        // The offscreen building image is needed only when buildings composite over
        // the map translucently (translucent, or the solidAtHighZoom zoom
        // transition): they render into it opaquely (depth test, MSAA), and the
        // world pass composites the result over the map with a single blend at a
        // shared alpha, so every pixel is tinted exactly once with no seams
        // between surfaces. Fully opaque buildings render straight into the world pass.
        if frameContext.renderSurfaceMode == .flat,
           case .composited = BuildingExtrusionPathResolver.resolve(style: settings.style,
                                                                    zoom: frameContext.zoom),
           let buildingImageTexture = attachments.ensureBuildingImageTexture(drawSize: frameContext.drawSize,
                                                                             pixelFormat: target.texture.pixelFormat) {
            resourceRegistry.setTexture(buildingImageTexture, named: .buildingImageTexture)
            nodes.append(RenderPassNode(name: .buildingImage,
                                        descriptorProvider: BuildingImageDescriptorProvider(),
                                        layers: [.buildingImage]))
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
