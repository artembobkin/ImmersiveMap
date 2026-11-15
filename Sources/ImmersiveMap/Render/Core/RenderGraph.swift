// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// Runtime graph of render subsystems, shared frame resources, and pass availability providers.
final class RenderGraph {
    let resourceRegistry: RenderResourceRegistry

    private let registry: RenderSubsystemRegistry
    private let availabilityProviders: [any RenderPassAvailabilityProvider]

    init(registry: RenderSubsystemRegistry,
         availabilityProviders: [any RenderPassAvailabilityProvider],
         resourceRegistry: RenderResourceRegistry = RenderResourceRegistry()) {
        self.registry = registry
        self.availabilityProviders = availabilityProviders
        self.resourceRegistry = resourceRegistry
    }

    func passAvailability(settings: ImmersiveMapSettings,
                          renderSurfaceMode: ViewMode) -> RenderPassAvailability {
        var builder = RenderPassAvailabilityBuilder(renderSurfaceMode: renderSurfaceMode)
        for provider in availabilityProviders {
            provider.contributePassAvailability(settings: settings,
                                                builder: &builder)
        }
        return builder.build()
    }

    func update(frameContext: FrameContext) {
        registry.update(frameContext: frameContext)
    }

    func prepareGPU(frameContext: FrameContext) {
        registry.prepareGPU(frameContext: frameContext,
                            resourceRegistry: resourceRegistry)
    }

    func encode(layer: RenderLayer,
                encoder: MTLRenderCommandEncoder,
                frameContext: FrameContext) {
        registry.encode(layer: layer,
                        encoder: encoder,
                        frameContext: frameContext)
    }

    func frameCommitted() {
        registry.frameCommitted()
    }

    func handleMemoryWarning() {
        registry.handleMemoryWarning()
    }

    func evict() {
        registry.evict()
    }
}
