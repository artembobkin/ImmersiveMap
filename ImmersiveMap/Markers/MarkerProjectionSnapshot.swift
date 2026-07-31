// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import simd

/// Screen position of one marker in drawable pixels (origin at bottom left,
/// y up). `visibilityAlpha` carries the soft globe-horizon fade.
struct MarkerProjectedEntry: Equatable, Sendable {
    let id: UInt64
    let positionPx: SIMD2<Float>
    let visibilityAlpha: Float
}

/// Per-frame snapshot of the marker projection. `entries` contains only visible
/// markers: an absent id means "hide the view".
struct MarkerProjectionSnapshot: Equatable, Sendable {
    static let empty = MarkerProjectionSnapshot(frameIndex: 0,
                                                drawSize: .zero,
                                                entries: [])

    let frameIndex: UInt64
    let drawSize: CGSize
    let entries: [MarkerProjectedEntry]
}
