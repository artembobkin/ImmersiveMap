// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// Stateless layout math shared by the UIKit and AppKit attribution badges.
/// All coordinates are top-left origin: valid as-is on iOS, and on macOS
/// because the badge view is flipped.
enum AttributionBadgeLayoutMath {
    /// Concrete metrics of one badge size preset. `regular` matches the
    /// historical constants exactly, so the default rendering is unchanged.
    struct Metrics: Equatable {
        let titleFontSize: CGFloat
        let copyrightFontSize: CGFloat
        let horizontalInset: CGFloat
        let verticalInset: CGFloat
        let interLabelSpacing: CGFloat
        let cornerRadius: CGFloat
        let containerInset: CGFloat
        let maximumWidth: CGFloat
    }

    static func metrics(for size: ImmersiveMapSettings.AttributionSettings.Size) -> Metrics {
        switch size {
        case .small:
            return Metrics(titleFontSize: 10,
                           copyrightFontSize: 8,
                           horizontalInset: 8,
                           verticalInset: 5,
                           interLabelSpacing: 2,
                           cornerRadius: 6,
                           containerInset: 10,
                           maximumWidth: 200)
        case .regular:
            return Metrics(titleFontSize: 12,
                           copyrightFontSize: 10,
                           horizontalInset: 10,
                           verticalInset: 7,
                           interLabelSpacing: 2,
                           cornerRadius: 8,
                           containerInset: 12,
                           maximumWidth: 240)
        case .large:
            return Metrics(titleFontSize: 14,
                           copyrightFontSize: 12,
                           horizontalInset: 12,
                           verticalInset: 9,
                           interLabelSpacing: 3,
                           cornerRadius: 10,
                           containerInset: 14,
                           maximumWidth: 300)
        }
    }

    /// Width the badge may occupy: bounds minus safe area minus the
    /// container inset on both sides.
    static func availableWidth(bounds: CGRect,
                               safeAreaInsets: PlatformEdgeInsets,
                               metrics: Metrics) -> CGFloat {
        max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right - metrics.containerInset * 2)
    }

    /// Plate size from measured label sizes. A zero copyright size means a
    /// one-line badge: neither the second row nor the inter-label spacing
    /// contributes.
    static func badgeSize(titleSize: CGSize,
                          copyrightSize: CGSize,
                          metrics: Metrics,
                          boundingWidth: CGFloat) -> CGSize {
        let maximumTextWidth = max(0, min(metrics.maximumWidth, boundingWidth) - metrics.horizontalInset * 2)
        let textWidth = max(min(titleSize.width, maximumTextWidth),
                            min(copyrightSize.width, maximumTextWidth))
        let width = min(boundingWidth, ceil(textWidth + metrics.horizontalInset * 2))
        let copyrightHeight = copyrightSize.height > 0
            ? copyrightSize.height + metrics.interLabelSpacing
            : 0
        let height = ceil(titleSize.height + copyrightHeight + metrics.verticalInset * 2)

        return CGSize(width: width, height: height)
    }

    /// Badge frame for a position, safe-area aware. Leading/trailing flip
    /// with the layout direction; centers do not.
    static func badgeFrame(badgeSize: CGSize,
                           position: ImmersiveMapSettings.AttributionSettings.Position,
                           bounds: CGRect,
                           safeAreaInsets: PlatformEdgeInsets,
                           metrics: Metrics,
                           isRightToLeft: Bool) -> CGRect {
        let contentRect = CGRect(x: safeAreaInsets.left + metrics.containerInset,
                                 y: safeAreaInsets.top + metrics.containerInset,
                                 width: max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right
                                            - metrics.containerInset * 2),
                                 height: max(0, bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
                                             - metrics.containerInset * 2))

        enum HorizontalAnchor {
            case leading
            case trailing
            case center
        }

        let horizontal: HorizontalAnchor
        let isTop: Bool
        switch position {
        case .bottomTrailing:
            horizontal = .trailing
            isTop = false
        case .bottomLeading:
            horizontal = .leading
            isTop = false
        case .topTrailing:
            horizontal = .trailing
            isTop = true
        case .topLeading:
            horizontal = .leading
            isTop = true
        case .bottomCenter:
            horizontal = .center
            isTop = false
        case .topCenter:
            horizontal = .center
            isTop = true
        }

        let x: CGFloat
        switch horizontal {
        case .leading:
            x = isRightToLeft ? contentRect.maxX - badgeSize.width : contentRect.minX
        case .trailing:
            x = isRightToLeft ? contentRect.minX : contentRect.maxX - badgeSize.width
        case .center:
            x = contentRect.midX - badgeSize.width / 2
        }
        let y = isTop ? contentRect.minY : contentRect.maxY - badgeSize.height

        return CGRect(x: x, y: y, width: badgeSize.width, height: badgeSize.height)
    }

    /// Title/copyright frames inside the plate; a zero copyright height
    /// yields a zero copyright frame and no spacing.
    static func labelFrames(badgeBounds: CGRect,
                            titleHeight: CGFloat,
                            copyrightHeight: CGFloat,
                            metrics: Metrics) -> (title: CGRect, copyright: CGRect) {
        let textFrame = badgeBounds.insetBy(dx: metrics.horizontalInset, dy: metrics.verticalInset)
        let title = CGRect(x: textFrame.minX,
                           y: textFrame.minY,
                           width: textFrame.width,
                           height: titleHeight)
        guard copyrightHeight > 0 else {
            return (title, CGRect(x: textFrame.minX, y: title.maxY, width: textFrame.width, height: 0))
        }

        let copyright = CGRect(x: textFrame.minX,
                               y: title.maxY + metrics.interLabelSpacing,
                               width: textFrame.width,
                               height: copyrightHeight)
        return (title, copyright)
    }
}
