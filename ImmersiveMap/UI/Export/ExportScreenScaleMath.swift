// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics

/// Picks the pixels-per-point an offscreen export renders at.
///
/// An export has no display to ask, but it still has to choose how big a point
/// is, because that is what decides how large labels and markers come out
/// relative to the frame. Rendering at 1 would size a 1080p frame as if it were
/// a 1920 by 1080 point canvas, roughly twice the width of a laptop screen, and
/// the labels would come out half the size a viewer expects.
///
/// The rule is the one a display follows: keep the point canvas the same and
/// spend extra resolution on detail. A 4K export is then the same composition as
/// a 1080p one, rendered sharper, rather than the same frame with twice as much
/// map crammed into it.
enum ExportScreenScaleMath {
    /// Short side of the point canvas an export is composed for. 1080p lands on
    /// 2 pixels per point, which is what `ImmersiveMapStillConfiguration`
    /// defaults to and what a Retina display of that size reports.
    static let referenceShortSidePoints: CGFloat = 540

    /// Keeps a 512 by 512 thumbnail from rendering at a fraction of a pixel per
    /// point, and a very large frame from asking for a scale no atlas is sized
    /// for.
    static let supportedRange: ClosedRange<CGFloat> = 1...8

    static func pixelsPerPoint(forOutputSize size: CGSize) -> CGFloat {
        let shortSidePixels = min(size.width, size.height)
        guard shortSidePixels.isFinite, shortSidePixels > 0 else {
            return CGFloat(ScreenScale.reference.pixelsPerPoint)
        }
        let scale = shortSidePixels / referenceShortSidePoints
        return min(max(scale, supportedRange.lowerBound), supportedRange.upperBound)
    }
}
