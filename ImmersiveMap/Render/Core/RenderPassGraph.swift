// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

final class RenderPassGraph {
    static func isWorldLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .starfield, .globeVectorSurface, .globeCap,
             .tileOwnership, .flatMapSurface, .buildingExtrusion, .sceneModels, .horizon:
            return true
        case .shadowCasters, .groundShadowMask, .postProcessing, .sceneModelOcclusion,
             .labels, .avatars, .debugOverlay:
            return false
        }
    }

    static func isOverlayLayer(_ layer: RenderLayer) -> Bool {
        switch layer {
        case .sceneModelOcclusion, .labels, .avatars, .debugOverlay:
            return true
        case .shadowCasters, .groundShadowMask, .starfield,
             .globeVectorSurface, .globeCap, .tileOwnership, .flatMapSurface,
             .buildingExtrusion, .sceneModels, .horizon, .postProcessing:
            return false
        }
    }

    /// Without the scene-model occlusion prepass the overlay layers need no
    /// depth of their own: they fold into the end of the world pass (the
    /// labels then draw with depth disabled, the same bit read by the label
    /// subsystems via `sceneModelState.hasDrawnModels`), which drops a whole
    /// drawable load/store round trip and puts the labels under the
    /// post-processing antialiasing. With models on screen the overlay keeps
    /// its own pass and its own cleared depth. So does a multisampled world
    /// pass: the overlay pipelines are single-sample, and Metal accepts them
    /// only in a single-sample pass, which the overlay pass is, over the
    /// resolved image.
    static func mergesOverlayIntoWorld(overlayLayers: [RenderLayer], renderSampleCount: Int) -> Bool {
        overlayLayers.contains(.sceneModelOcclusion) == false && renderSampleCount == 1
    }

    /// The world pass draw order for the frame. The planner lists the flat
    /// layers ground first; the order flips so the opaque buildings write
    /// depth before the ground is drawn and every ground fragment under a
    /// building fails its depth test unshaded (the ground writes only its
    /// rank band, farther than any building, so the flip changes nothing
    /// else).
    static func worldLayerOrder(_ layers: [RenderLayer]) -> [RenderLayer] {
        guard let surfaceIndex = layers.firstIndex(of: .flatMapSurface),
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
    /// be stored for sampling by the world pass.
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
                // The stencil half of the texture carries the tile-priority
                // marks (TileSourceStencilPriority): cleared to 0, written by
                // the ground's owner passes, never stored.
                descriptor.stencilAttachment.texture = depthTexture
                descriptor.stencilAttachment.loadAction = .clear
                descriptor.stencilAttachment.storeAction = .dontCare
                descriptor.stencilAttachment.clearStencil = 0
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
            // The pipelines of the overlay layers are shared with the world
            // pass (where the overlay merges on model-free frames), so the
            // two passes must agree on the depth-stencil format.
            descriptor.stencilAttachment.texture = depthTexture
            descriptor.stencilAttachment.loadAction = .clear
            descriptor.stencilAttachment.storeAction = .dontCare
            descriptor.stencilAttachment.clearStencil = 0
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
        // The shadow map goes first: the world pass samples it. The gate skips the pass entirely when shadows are off
        // or the frame has no casters, and the receivers then bind the fallback
        // texture with a disabled uniform (same resolver on both sides).
        if let shadowState = ShadowPassGateResolver.resolve(frameContext: frameContext),
           let shadowMapTexture = attachments.ensureShadowMapTexture(resolution: shadowState.mapResolution) {
            resourceRegistry.setTexture(shadowMapTexture, named: .shadowMapTexture)
            // The sun is static and the buildings do not move: the caster
            // pass runs only when the rendered map went stale (fresh fit,
            // new caster tile, new texture, or animating model casters);
            // otherwise the receivers keep sampling the map rendered some
            // frames ago through matrices re-materialized for this frame.
            if frameContext.shadowMapReuse.planShadowRender(frameContext: frameContext,
                                                            texture: shadowMapTexture) {
                nodes.append(RenderPassNode(name: .shadowMap,
                                            descriptorProvider: ShadowMapDescriptorProvider(),
                                            layers: [.shadowCasters]))
            }
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
        let worldLayers = Self.worldLayerOrder(layerPlan.filter(Self.isWorldLayer))
        let overlayLayers = layerPlan.filter(Self.isOverlayLayer)
        let outputPlan = RenderFrameOutputPlanner.plan(
            fxaaEnabled: settings.postProcessing.fxaaEnabled,
            renderSampleCount: attachments.sampleCount
        )

        let mergesOverlayIntoWorld = Self.mergesOverlayIntoWorld(overlayLayers: overlayLayers,
                                                                 renderSampleCount: attachments.sampleCount)
        nodes.append(RenderPassNode(name: .world,
                                    descriptorProvider: WorldDescriptorProvider(clearColor: clearColor,
                                                                                depthTexture: depthTexture,
                                                                                outputPlan: outputPlan),
                                    layers: mergesOverlayIntoWorld ? worldLayers + overlayLayers : worldLayers))
        if outputPlan.includesPostProcessingPass {
            nodes.append(RenderPassNode(name: .postProcessing,
                                        descriptorProvider: PostProcessingDescriptorProvider(),
                                        layers: [.postProcessing]))
        }
        if mergesOverlayIntoWorld == false, overlayLayers.isEmpty == false {
            nodes.append(RenderPassNode(name: .overlay,
                                        descriptorProvider: OverlayDescriptorProvider(),
                                        layers: overlayLayers))
        }
        return nodes
    }
}
