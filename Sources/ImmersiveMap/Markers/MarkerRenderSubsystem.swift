// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Projects SwiftUI marker coordinates into the frame's screen points with the
/// same formulas as the render's vertex path (GeoScreenProjectionMath).
/// Does no GPU work: the result is stored in
/// `frameContext.sharedState.markerState`, and the engine publishes it
/// synchronously after a successful present of the same frame.
final class MarkerRenderSubsystem: RenderSubsystem {
    let name: String = "Markers"

    private let markerSource: MarkerRenderSource

    init(markerSource: MarkerRenderSource) {
        self.markerSource = markerSource
    }

    func update(frameContext: FrameContext) {
        let input = markerSource.currentMarkerProjectionInput
        guard input.entries.isEmpty == false else {
            frameContext.sharedState.markerState = .empty
            return
        }

        let constants = GeoScreenProjectionMath.FrameConstants(
            drawSize: frameContext.drawSize,
            cameraUniform: frameContext.cameraUniform,
            resolvedPresentation: frameContext.resolvedPresentation)

        var entries: [MarkerProjectedEntry] = []
        entries.reserveCapacity(input.entries.count)
        for entry in input.entries {
            let point = GeoScreenProjectionMath.project(basis: entry.basis,
                                                        constants: constants)
            guard point.visible != 0, point.visibilityAlpha > 0.0 else {
                continue
            }
            entries.append(MarkerProjectedEntry(id: entry.id,
                                                positionPx: point.position,
                                                visibilityAlpha: point.visibilityAlpha))
        }
        frameContext.sharedState.markerState.snapshot = MarkerProjectionSnapshot(
            frameIndex: frameContext.frameIndex,
            drawSize: frameContext.drawSize,
            entries: entries)
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    func handleMemoryWarning() {}

    func evict() {}
}
