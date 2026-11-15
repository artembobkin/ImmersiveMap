// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// Projects SwiftUI annotation coordinates into the frame's screen points with the
/// same formulas as the render's vertex path (GeoScreenProjectionMath).
/// Does no GPU work: the result is stored in
/// `frameContext.sharedState.annotationState`, and the engine publishes it
/// synchronously after a successful present of the same frame.
final class AnnotationRenderSubsystem: RenderSubsystem {
    let name: String = "Annotations"

    private let annotationSource: AnnotationRenderSource

    init(annotationSource: AnnotationRenderSource) {
        self.annotationSource = annotationSource
    }

    func update(frameContext: FrameContext) {
        let input = annotationSource.currentAnnotationProjectionInput
        guard input.entries.isEmpty == false else {
            frameContext.sharedState.annotationState = .empty
            return
        }

        let constants = GeoScreenProjectionMath.FrameConstants(
            drawSize: frameContext.drawSize,
            cameraUniform: frameContext.cameraUniform,
            resolvedPresentation: frameContext.resolvedPresentation)

        var entries: [AnnotationProjectedEntry] = []
        entries.reserveCapacity(input.entries.count)
        for entry in input.entries {
            let point = GeoScreenProjectionMath.project(basis: entry.basis,
                                                        constants: constants)
            guard point.visible != 0, point.visibilityAlpha > 0.0 else {
                continue
            }
            entries.append(AnnotationProjectedEntry(id: entry.id,
                                                positionPx: point.position,
                                                visibilityAlpha: point.visibilityAlpha))
        }
        frameContext.sharedState.annotationState.snapshot = AnnotationProjectionSnapshot(
            frameIndex: frameContext.frameIndex,
            drawSize: frameContext.drawSize,
            entries: entries)
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    func handleMemoryWarning() {}

    func evict() {}
}
