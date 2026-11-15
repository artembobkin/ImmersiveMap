// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import SwiftUI
import UIKit

/// Transparent container for SwiftUI annotations above the Metal layer. Occupies the
/// entire host view, but only annotation content receives touches: "empty" points
/// fall through to the map (precedents: AttributionBadgeView,
/// DebugOverlayHUDView).
final class AnnotationOverlayContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
}

/// Wrapper for a single annotation: owns the content's `UIHostingController` and
/// toggles interactivity (a annotation near the horizon with almost zero alpha
/// must not catch touches).
@MainActor
final class AnnotationOverlayItemHost {
    /// No parent view controller: annotation content is a closed leaf
    /// (navigation or presentation from inside it is unsupported), and its
    /// traits arrive through the window.
    private let hostingController: UIHostingController<AnnotationSizedContent>
    /// Called when SwiftUI laid the content out at another size.
    var onSizeChange: ((CGSize) -> Void)?
    private let sizeReport = AnnotationSizeReport()

    var view: UIView {
        hostingController.view
    }

    init(content: AnyView) {
        hostingController = UIHostingController(rootView: AnnotationSizedContent(content: content,
                                                                           onSizeChange: sizeReport.send))
        hostingController.view.backgroundColor = .clear
        hostingController.view.isHidden = true
        hostingController.sizingOptions = [.intrinsicContentSize]
        // The keyboard and safe area must not move the annotation content.
        hostingController.safeAreaRegions = []
        sizeReport.receive = { [weak self] size in self?.onSizeChange?(size) }
    }

    func update(content: AnyView) {
        hostingController.rootView = AnnotationSizedContent(content: content, onSizeChange: sizeReport.send)
    }

    func idealSize() -> CGSize {
        hostingController.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude))
    }

    func apply(frame: CGRect, alpha: CGFloat) {
        view.frame = frame
        view.alpha = alpha
        view.isHidden = false
        view.isUserInteractionEnabled = alpha > AnnotationOverlayLayoutMath.interactionAlphaThreshold
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
