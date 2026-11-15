// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Screen position of one annotation in drawable pixels (origin at bottom left,
/// y up). `visibilityAlpha` carries the soft globe-horizon fade.
struct AnnotationProjectedEntry: Equatable, Sendable {
    let id: UInt64
    let positionPx: SIMD2<Float>
    let visibilityAlpha: Float
}

/// Per-frame snapshot of the annotation projection. `entries` contains only visible
/// annotations: an absent id means "hide the view".
struct AnnotationProjectionSnapshot: Equatable, Sendable {
    static let empty = AnnotationProjectionSnapshot(frameIndex: 0,
                                                drawSize: .zero,
                                                entries: [])

    let frameIndex: UInt64
    let drawSize: CGSize
    let entries: [AnnotationProjectedEntry]
}
