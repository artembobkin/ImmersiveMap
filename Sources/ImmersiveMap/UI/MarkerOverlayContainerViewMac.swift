// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import SwiftUI

/// Transparent container for SwiftUI markers above the Metal layer. Occupies
/// the whole host view, but only marker content receives clicks: "empty"
/// points fall through to the map, and `MapGestureControllerMac` uses
/// `hitTest` to automatically suppress map gestures over an interactive
/// marker (precedents: AttributionBadgeView, DebugOverlayHUDView).
final class MarkerOverlayContainerView: NSView {
    /// Top-left origin, like the flipped `ImmersiveMapNSView`: marker layout
    /// math is shared with UIKit.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}

/// Wrapper of a single marker: owns the content's `NSHostingView` and toggles
/// interactivity via hitTest (NSView has no isUserInteractionEnabled).
@MainActor
final class MarkerOverlayItemHost {
    private final class ItemView: NSView {
        override var isFlipped: Bool { true }
        var isInteractionEnabled = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isInteractionEnabled else {
                return nil
            }
            return super.hitTest(point)
        }
    }

    private let itemView: ItemView
    private let hostingView: NSHostingView<AnyView>

    var view: NSView {
        itemView
    }

    init(content: AnyView) {
        hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = [.intrinsicContentSize]
        itemView = ItemView(frame: .zero)
        // alphaValue requires a layer; the host view is layer-backed anyway.
        itemView.wantsLayer = true
        itemView.isHidden = true
        hostingView.autoresizingMask = [.width, .height]
        itemView.addSubview(hostingView)
    }

    func update(content: AnyView) {
        hostingView.rootView = content
    }

    func idealSize() -> CGSize {
        hostingView.fittingSize
    }

    func apply(frame: CGRect, alpha: CGFloat) {
        itemView.frame = frame
        hostingView.frame = itemView.bounds
        itemView.alphaValue = alpha
        itemView.isHidden = false
        itemView.isInteractionEnabled = alpha > MarkerOverlayLayoutMath.interactionAlphaThreshold
    }

    func hide() {
        itemView.isHidden = true
        itemView.isInteractionEnabled = false
    }

    func removeFromContainer() {
        itemView.removeFromSuperview()
    }
}

#endif
