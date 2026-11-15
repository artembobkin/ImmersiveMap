// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  DebugOverlayRenderSubsystem.swift
//  ImmersiveMap
//

import Metal

final class DebugOverlayRenderSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "DebugOverlay"

    private let polygonPipeline: PolygonsPipeline
    private let debugOverlayRenderer: DebugOverlayRenderer
    private let textRenderer: TextRenderer
    private let controls: DebugOverlayControlState

    init(polygonPipeline: PolygonsPipeline,
         debugOverlayRenderer: DebugOverlayRenderer,
         textRenderer: TextRenderer,
         controls: DebugOverlayControlState) {
        self.polygonPipeline = polygonPipeline
        self.debugOverlayRenderer = debugOverlayRenderer
        self.textRenderer = textRenderer
        self.controls = controls
    }

    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.debugOverlayEnabled = builder.debugOverlayEnabled
            || RenderDebugOverlayPolicy.shouldEncode(settings.debug,
                                                     controls: controls.snapshot())
    }

    func update(frameContext: FrameContext) {}

    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .debugOverlay else { return }
        RendererDebugOverlayDrawer.draw(renderEncoder: encoder,
                                        frameContext: frameContext,
                                        polygonPipeline: polygonPipeline,
                                        debugOverlayRenderer: debugOverlayRenderer,
                                        textRenderer: textRenderer,
                                        controls: controls.snapshot())
    }

    func handleMemoryWarning() {}

    func evict() {}
}
