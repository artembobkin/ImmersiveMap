// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)
import UIKit
typealias RendererUnavailableViewBase = UIView
#elseif os(macOS)
import AppKit
typealias RendererUnavailableViewBase = NSView
#endif

/// What the map view shows in place of the map when the renderer cannot be
/// built: one centred paragraph that says the map cannot draw and why
/// (`RenderResourcesError`, `ImmersiveMapResourceBundle.NotFound`), over the
/// view's background. It fills the map view, follows its size, and lets
/// every touch and click through. The host runtime adds it when a renderer
/// creation fails and removes it when one succeeds.
final class RendererUnavailableView: RendererUnavailableViewBase {
    #if canImport(UIKit)
    private let label = UILabel()
    #else
    private let label = NSTextField(wrappingLabelWithString: "")
    #endif

    /// The space between the text and the map view's edges, in points.
    private static let margin: CGFloat = 24

    init(error: any Error) {
        super.init(frame: .zero)
        let text = "The map cannot draw.\n\(error.localizedDescription)"
        #if canImport(UIKit)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.text = text
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = false
        #else
        autoresizingMask = [.width, .height]
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .preferredFont(forTextStyle: .footnote)
        label.stringValue = text
        label.isSelectable = false
        #endif
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
    }
    #else
    override func layout() {
        super.layout()
        let available = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        label.preferredMaxLayoutWidth = max(available.width, 0)
        let height = min(label.intrinsicContentSize.height, available.height)
        label.frame = CGRect(x: available.minX,
                             y: available.midY - height / 2,
                             width: available.width,
                             height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
    #endif
}
