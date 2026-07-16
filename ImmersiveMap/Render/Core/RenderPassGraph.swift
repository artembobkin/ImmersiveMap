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
                                      drawable: CAMetalDrawable?) -> MTLRenderPassDescriptor? {
            guard frameContext.renderSurfaceMode == .flat,
                  let drawable,
                  let buildingImageTexture = attachments.ensureBuildingImageTexture(drawSize: frameContext.drawSize,
                                                                                    pixelFormat: drawable.texture.pixelFormat),
                  let depthTexture = attachments.ensureDepthTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            if attachments.sampleCount > 1 {
                guard let msaaColorTexture = attachments.ensureBuildingImageColorTexture(drawSize: frameContext.drawSize,
                                                                                         pixelFormat: drawable.texture.pixelFormat) else {
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
            // Прозрачный фон: после resolve альфа хранит покрытие силуэта
            // зданий, а цвет - премультиплицирован этим покрытием.
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            // Depth переиспользуется с world-пассом: оба пасса стартуют с .clear
            // и не читают прошлое содержимое, поэтому хазарда между ними нет.
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
        // Offscreen building image нужен, только когда здания накладываются на
        // карту полупрозрачно (translucent или зум-переход solidAtHighZoom):
        // они рисуются в него непрозрачно (depth-тест, MSAA), а world-пасс
        // накладывает результат на карту одним блендом с общей альфой - каждый
        // пиксель тонируется ровно один раз, без швов между поверхностями.
        // Полностью непрозрачные здания рисуются прямо в world-пасс.
        if frameContext.renderSurfaceMode == .flat,
           case .composited = BuildingExtrusionPathResolver.resolve(style: settings.style,
                                                                    zoom: frameContext.zoom),
           let buildingImageTexture = attachments.ensureBuildingImageTexture(drawSize: frameContext.drawSize,
                                                                             pixelFormat: drawable.texture.pixelFormat) {
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
