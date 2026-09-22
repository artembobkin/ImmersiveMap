// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import SwiftUI
import simd

/// Pure layout math for marker hosting views: converting projection
/// drawable pixels to view points and anchor-based positioning.
enum MarkerOverlayLayoutMath {
    /// Below this alpha a marker near the globe horizon counts as non-interactive.
    /// Same semantics as `AvatarVisibilityFadeStateStore.activeAlphaThreshold`:
    /// any visible marker is interactive.
    static let interactionAlphaThreshold: CGFloat = 0.0001

    /// The projection yields drawable pixels with a bottom-left origin and y up,
    /// while the view layer lives in points with a top-left origin (NSView flipped):
    /// x = px / scale, y = (drawSize.height - py) / scale.
    /// Inverse of the conversion in `ImmersiveMapSelectionHandler.avatarHitTarget`.
    static func pointFromPixel(_ positionPx: SIMD2<Float>,
                               drawSize: CGSize,
                               contentsScale: CGFloat) -> CGPoint {
        guard contentsScale > 0 else {
            return .zero
        }
        return CGPoint(x: CGFloat(positionPx.x) / contentsScale,
                       y: (drawSize.height - CGFloat(positionPx.y)) / contentsScale)
    }

    /// Frames the marker so the `anchor` point of its bounds lands on the
    /// projected point: origin = point - anchor * size.
    static func frame(anchorPoint: CGPoint,
                      size: CGSize,
                      anchor: UnitPoint) -> CGRect {
        CGRect(x: anchorPoint.x - size.width * anchor.x,
               y: anchorPoint.y - size.height * anchor.y,
               width: size.width,
               height: size.height)
    }
}
