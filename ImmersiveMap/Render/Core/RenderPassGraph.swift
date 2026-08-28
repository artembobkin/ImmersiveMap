// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

final class RenderPassGraph {
    static func isWorldLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .starfield, .atmosphere, .globeSurface, .globeVectorSurface, .globeCap, .flatMapSurface,
             .buildingExtrusion, .sceneModels, .routes:
            return true
        case .shadowCasters, .groundShadowMask, .buildingImage, .postProcessing, .sceneModelOcclusion,
             .labels, .avatars, .debugOverlay:
            return false
        }
    }

    static func isOverlayLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .sceneModelOcclusion, .labels, .avatars, .debugOverlay:
            return true
        case .shadowCasters, .groundShadowMask, .buildingImage, .starfield, .atmosphere, .globeSurface,
             .globeVectorSurface, .globeCap, .flatMapSurface, .buildingExtrusion, .sceneModels, .routes,
             .postProcessing:
            return false
        }
    }

    /// The world pass draw order for the frame. The planner lists the flat
    /// layers ground first; with solid buildings the order flips so the
    /// opaque buildings write depth before the ground is drawn and every
    /// ground fragment under a building fails its depth test unshaded (the
    /// ground itself never writes depth, so the flip changes nothing else).
    /// Composited buildings keep the planner's order: the ground must be
    /// shaded under a translucent building for it to show through.
    static func worldLayerOrder(_ layers: [RenderLayer],
                                buildingPath: BuildingExtrusionPathResolver.Path?) -> [RenderLayer] {
        guard buildingPath == .solid,
              let surfaceIndex = layers.firstIndex(of: .flatMapSurface),
              let buildingIndex = layers.firstIndex(of: .buildingExtrusion),
              surfaceIndex < buildingIndex else {
            return layers
        }
        var ordered = layers
        ordered.remove(at: buildingIndex)
        ordered.insert(.buildingExtrusion, at: surfaceIndex)
        return ordered
    }

    /// Depth-only pass of the directional light. Ignores the drawable target:
    /// the shadow map is a fixed-resolution offscreen depth texture that must
    /// be stored for sampling by the buildingImage and world passes.
    private final class ShadowMapDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target _: FrameRenderTarget?) -> MTLRenderPassDescriptor? {
            guard let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
                  let shadowMapTexture = attachments.ensureShadowMapTexture(resolution: shadowState.mapResolution) else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.depthAttachment.texture = shadowMapTexture
            descriptor.depthAttachment.loadAction = .clear
            descriptor.depthAttachment.storeAction = .store
            descriptor.depthAttachment.clearDepth = 1.0
            // Layered rendering: the caster vertex stages route each instance
            // to its cascade's slice via [[render_target_array_index]].
            descriptor.renderTargetArrayLength = ShadowCascadeAtlas.cascadeCount
            return descriptor
        }
    }

    /// The ground shadow mask: a single-sample 8-bit target the size of the
    /// drawable, fully overwritten by one fullscreen triangle (so nothing to
    /// load) and stored for the world pass to read.
    private final class GroundShadowMaskDescriptorProvider: RenderPassDescriptorProvider {
        func makeRenderPassDescriptor(frameContext: FrameContext,
                                      attachments: FrameAttachmentStore,
                                      target _: FrameRenderTarget?) -> MTLRenderPassDescriptor? {
            guard frameContext.renderSurfaceMode == .flat,
                  ShadowPassGateResolver.resolve(frameContext: frameContext) != nil,
                  let maskTexture = attachments.ensureGroundShadowMaskTexture(drawSize: frameContext.drawSize) else {
                return nil
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = maskTexture
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            return descriptor
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
        /// Framebuffer-fetch composited buildings: the pass carries a second,
        /// memoryless color attachment the buildings render into and the
        /// composite reads back, so the intermediate never leaves tile memory.
        private let includesBuildingImageAttachment: Bool

        init(clearColor: MTLClearColor,
             depthTexture: MTLTexture?,
             outputPlan: RenderFrameOutputPlan,
             includesBuildingImageAttachment: Bool) {
            self.clearColor = clearColor
            self.depthTexture = depthTexture
            self.outputPlan = outputPlan
            self.includesBuildingImageAttachment = includesBuildingImageAttachment
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
            if includesBuildingImageAttachment {
                guard let worldBuildingImage = attachments.ensureWorldBuildingImageTexture(
                    drawSize: frameContext.drawSize,
                    pixelFormat: target.texture.pixelFormat
                ) else {
                    return nil
                }
                descriptor.colorAttachments[1].texture = worldBuildingImage
                descriptor.colorAttachments[1].loadAction = .clear
                descriptor.colorAttachments[1].storeAction = .dontCare
                // Transparent: per sample, the alpha becomes the building
                // silhouette coverage the composite blends with.
                descriptor.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
            }
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
        // The shadow map goes first: both the buildingImage pass and the world
        // pass sample it. The gate skips the pass entirely when shadows are off
        // or the frame has no casters, and the receivers then bind the fallback
        // texture with a disabled uniform (same resolver on both sides).
        if let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
           let shadowMapTexture = attachments.ensureShadowMapTexture(resolution: shadowState.mapResolution) {
            resourceRegistry.setTexture(shadowMapTexture, named: .shadowMapTexture)
            nodes.append(RenderPassNode(name: .shadowMap,
                                        descriptorProvider: ShadowMapDescriptorProvider(),
                                        layers: [.shadowCasters]))
            // The ground shadow mask follows the map it samples: one cascade
            // lookup per pixel on the ground plane, read by every blended
            // ground layer of the world pass instead of a lookup per layer.
            if frameContext.renderSurfaceMode == .flat,
               let maskTexture = attachments.ensureGroundShadowMaskTexture(drawSize: frameContext.drawSize) {
                resourceRegistry.setTexture(maskTexture, named: .groundShadowMaskTexture)
                nodes.append(RenderPassNode(name: .groundShadowMask,
                                            descriptorProvider: GroundShadowMaskDescriptorProvider(),
                                            layers: [.groundShadowMask]))
            }
        }
        // Composited buildings (translucent, or the solidAtHighZoom zoom
        // transition) render opaquely into a building image (depth test,
        // MSAA), which is then blended over the map once at a shared alpha, so
        // every pixel is tinted exactly once with no seams between surfaces.
        // On Apple GPUs the image is the world pass's second memoryless
        // attachment read back via framebuffer fetch; elsewhere it is a
        // separate offscreen pass whose resolve the world pass samples. Fully
        // opaque buildings render straight into the world pass.
        let usesInPassBuildingImage = BuildingExtrusionPathResolver.usesInPassBuildingImage(
            style: settings.style,
            zoom: frameContext.zoom,
            renderSurfaceMode: frameContext.renderSurfaceMode,
            supportsFramebufferFetch: attachments.supportsFramebufferFetch
        )
        if usesInPassBuildingImage == false,
           frameContext.renderSurfaceMode == .flat,
           case .composited = BuildingExtrusionPathResolver.resolve(style: settings.style,
                                                                    zoom: frameContext.zoom),
           let buildingImageTexture = attachments.ensureBuildingImageTexture(drawSize: frameContext.drawSize,
                                                                             pixelFormat: target.texture.pixelFormat) {
            resourceRegistry.setTexture(buildingImageTexture, named: .buildingImageTexture)
            nodes.append(RenderPassNode(name: .buildingImage,
                                        descriptorProvider: BuildingImageDescriptorProvider(),
                                        layers: [.buildingImage]))
        }
        var worldLayers = Self.worldLayerOrder(
            layerPlan.filter(Self.isWorldLayer),
            buildingPath: frameContext.renderSurfaceMode == .flat
                ? BuildingExtrusionPathResolver.resolve(style: settings.style, zoom: frameContext.zoom)
                : nil
        )
        if usesInPassBuildingImage,
           let buildingExtrusionIndex = worldLayers.firstIndex(of: .buildingExtrusion) {
            // The buildings render into the in-pass image right before the
            // composite reads it back.
            worldLayers.insert(.buildingImage, at: buildingExtrusionIndex)
        }
        let overlayLayers = layerPlan.filter(Self.isOverlayLayer)
        let outputPlan = RenderFrameOutputPlanner.plan(
            fxaaEnabled: settings.postProcessing.fxaaEnabled,
            renderSampleCount: attachments.sampleCount
        )

        nodes.append(RenderPassNode(name: .world,
                                    descriptorProvider: WorldDescriptorProvider(clearColor: clearColor,
                                                                                depthTexture: depthTexture,
                                                                                outputPlan: outputPlan,
                                                                                includesBuildingImageAttachment: usesInPassBuildingImage),
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
