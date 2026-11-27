// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import SwiftUI

/// Transparent container for SwiftUI annotations above the Metal layer. Occupies
/// the whole host view, but only annotation content receives clicks: "empty"
/// points fall through to the map, and `MapGestureControllerMac` uses
/// `hitTest` to automatically suppress map gestures over an interactive
/// annotation (precedents: AttributionBadgeView, DebugOverlayHUDView).
final class AnnotationOverlayContainerView: NSView {
    /// Top-left origin, like the flipped `ImmersiveMapNSView`: annotation layout
    /// math is shared with UIKit.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}

/// Wrapper of a single annotation: owns the content's `NSHostingView` and toggles
/// interactivity via hitTest (NSView has no isUserInteractionEnabled).
@MainActor
final class AnnotationOverlayItemHost {
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
    private let hostingView: NSHostingView<AnnotationSizedContent>
    /// Called when SwiftUI laid the content out at another size.
    var onSizeChange: ((CGSize) -> Void)?
    private let sizeReport = AnnotationSizeReport()

    var view: NSView {
        itemView
    }

    init(content: AnyView) {
        hostingView = NSHostingView(rootView: AnnotationSizedContent(content: content, onSizeChange: sizeReport.send))
        hostingView.sizingOptions = [.intrinsicContentSize]
        itemView = ItemView(frame: .zero)
        // alphaValue requires a layer; the host view is layer-backed anyway.
        itemView.wantsLayer = true
        itemView.isHidden = true
        hostingView.autoresizingMask = [.width, .height]
        itemView.addSubview(hostingView)
        sizeReport.receive = { [weak self] size in self?.onSizeChange?(size) }
    }

    func update(content: AnyView) {
        hostingView.rootView = AnnotationSizedContent(content: content, onSizeChange: sizeReport.send)
    }

    func idealSize() -> CGSize {
        hostingView.fittingSize
    }

    func apply(frame: CGRect, alpha: CGFloat) {
        itemView.frame = frame
        hostingView.frame = itemView.bounds
        itemView.alphaValue = alpha
        itemView.isHidden = false
        itemView.isInteractionEnabled = alpha > AnnotationOverlayLayoutMath.interactionAlphaThreshold
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
