// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import SwiftUI
import UIKit

/// Transparent container for SwiftUI markers above the Metal layer. Occupies the
/// entire host view, but only marker content receives touches: "empty" points
/// fall through to the map (precedents: AttributionBadgeView,
/// DebugOverlayHUDView).
final class MarkerOverlayContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
}

/// Wrapper for a single marker: owns the content's `UIHostingController` and
/// toggles interactivity (a marker near the horizon with almost zero alpha
/// must not catch touches).
@MainActor
final class MarkerOverlayItemHost {
    /// No parent view controller: marker content is a closed leaf
    /// (navigation/presentation from inside is unsupported, see docs/markers.md),
    /// traits arrive through the window.
    private let hostingController: UIHostingController<AnyView>

    var view: UIView {
        hostingController.view
    }

    init(content: AnyView) {
        hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        hostingController.view.isHidden = true
        hostingController.sizingOptions = [.intrinsicContentSize]
        // The keyboard and safe area must not move the marker content.
        hostingController.safeAreaRegions = []
    }

    func update(content: AnyView) {
        hostingController.rootView = content
    }

    func idealSize() -> CGSize {
        hostingController.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude))
    }

    func apply(frame: CGRect, alpha: CGFloat) {
        view.frame = frame
        view.alpha = alpha
        view.isHidden = false
        view.isUserInteractionEnabled = alpha > MarkerOverlayLayoutMath.interactionAlphaThreshold
    }

    func hide() {
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    func removeFromContainer() {
        view.removeFromSuperview()
    }
}

#endif
