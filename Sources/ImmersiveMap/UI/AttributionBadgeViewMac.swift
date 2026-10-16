// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit

/// Renders the compact attribution overlay (AppKit), as UIKit's does: plain
/// bold text over the map, no plate, each glyph in a dark halo that fades
/// out around it so the words read on any map colour underneath.
/// Owns only the badge labels, styling and layout; map state stays in the
/// surrounding runtimes. Size, position and text color come from
/// `AttributionSettings`; the geometry lives in `AttributionBadgeLayoutMath`.
final class AttributionBadgeView: NSView {
    /// The halo around every glyph, UIKit's badge's: a dark shadow on the
    /// glyph itself, blurred by this many points, so its edge fades into the
    /// map rather than ends in a hard line, which a stroke on glyphs this
    /// small draws ragged.
    static let haloBlurRadius: CGFloat = 3.5
    static let haloColor = NSColor.black.withAlphaComponent(0.95)

    private let titleLabel = NSTextField(labelWithString: "")
    private let copyrightLabel = NSTextField(labelWithString: "")
    private var linkURL: URL?
    private var metrics = AttributionBadgeLayoutMath.metrics(for: .regular)
    private var position = ImmersiveMapSettings.AttributionSettings.Position.bottomTrailing
    private var margin: CGFloat = 0

    override var isFlipped: Bool { true }

    convenience init(attribution: ImmersiveMapAttribution,
                     settings: ImmersiveMapSettings.AttributionSettings) {
        self.init(frame: .zero)
        apply(attribution, settings: settings)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for label in [titleLabel, copyrightLabel] {
            label.drawsBackground = false
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        copyrightLabel.lineBreakMode = .byTruncatingTail
        copyrightLabel.maximumNumberOfLines = 1

        addSubview(titleLabel)
        addSubview(copyrightLabel)

        let clickGesture = NSClickGestureRecognizer(target: self,
                                                    action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Without a link the badge is click-transparent - clicks go to the map.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard linkURL != nil else {
            return nil
        }

        return super.hitTest(point)
    }

    /// Empty attribution hides the badge entirely: no point drawing an empty badge.
    /// An empty copyright collapses the second line: the field must be hidden,
    /// not just emptied - an empty NSTextField still measures a nonzero size.
    func apply(_ attribution: ImmersiveMapAttribution,
               settings: ImmersiveMapSettings.AttributionSettings) {
        metrics = AttributionBadgeLayoutMath.metrics(for: settings.size)
        position = settings.position
        margin = CGFloat(settings.margin)
        isHidden = settings.isVisible == false || attribution.isEmpty
        linkURL = attribution.linkURL
        copyrightLabel.isHidden = attribution.copyright.isEmpty
        let color = settings.textColor ?? SIMD4<Float>(1, 1, 1, 1)
        titleLabel.attributedStringValue = Self.haloText(attribution.title,
                                                         font: .systemFont(ofSize: metrics.titleFontSize, weight: .bold),
                                                             color: color,
                                                             alpha: 1)
        copyrightLabel.attributedStringValue = Self.haloText(attribution.copyright,
                                                             font: .systemFont(ofSize: metrics.copyrightFontSize, weight: .semibold),
                                                                 color: color,
                                                                 alpha: 0.76)
        needsLayout = true
    }

    /// The text filled in the settings' colour in a dark halo that fades
    /// out around every glyph, which is what keeps it legible over water,
    /// forest or a dark palette alike without a plate behind it.
    static func haloText(_ text: String, font: NSFont, color: SIMD4<Float>, alpha: CGFloat) -> NSAttributedString {
        let fill = NSColor(red: CGFloat(color.x),
                           green: CGFloat(color.y),
                           blue: CGFloat(color.z),
                           alpha: CGFloat(color.w) * alpha)
        let halo = NSShadow()
        halo.shadowOffset = .zero
        halo.shadowBlurRadius = haloBlurRadius
        halo.shadowColor = haloColor.withAlphaComponent(haloColor.alphaComponent * alpha)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: fill,
            .shadow: halo
        ])
    }

    @objc private func handleClick() {
        guard let linkURL else {
            return
        }

        NSWorkspace.shared.open(linkURL)
    }

    func layout(in bounds: CGRect, safeAreaInsets: NSEdgeInsets) {
        let availableWidth = AttributionBadgeLayoutMath.availableWidth(bounds: bounds,
                                                                       safeAreaInsets: safeAreaInsets,
                                                                       margin: margin)
        let badgeSize = badgeSizeThatFits(CGSize(width: availableWidth,
                                                 height: bounds.height))
        frame = AttributionBadgeLayoutMath.badgeFrame(
            badgeSize: badgeSize,
            position: position,
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            margin: margin,
            isRightToLeft: userInterfaceLayoutDirection == .rightToLeft
        )
    }

    private func badgeSizeThatFits(_ size: CGSize) -> CGSize {
        guard isHidden == false else {
            return .zero
        }

        let maximumTextWidth = min(metrics.maximumWidth, size.width) - metrics.horizontalInset * 2
        let constrainedSize = CGSize(width: max(0, maximumTextWidth), height: .greatestFiniteMagnitude)
        let titleSize = titleLabel.sizeThatFits(constrainedSize)
        let copyrightSize = copyrightLabel.isHidden ? .zero : copyrightLabel.sizeThatFits(constrainedSize)

        return AttributionBadgeLayoutMath.badgeSize(titleSize: titleSize,
                                                    copyrightSize: copyrightSize,
                                                    metrics: metrics,
                                                    boundingWidth: size.width)
    }

    override func layout() {
        super.layout()

        let textWidth = bounds.insetBy(dx: metrics.horizontalInset, dy: metrics.verticalInset).width
        let constrainedSize = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let titleHeight = titleLabel.sizeThatFits(constrainedSize).height
        let copyrightHeight = copyrightLabel.isHidden
            ? 0
            : copyrightLabel.sizeThatFits(constrainedSize).height

        let frames = AttributionBadgeLayoutMath.labelFrames(badgeBounds: bounds,
                                                            titleHeight: titleHeight,
                                                            copyrightHeight: copyrightHeight,
                                                            metrics: metrics)
        titleLabel.frame = frames.title
        copyrightLabel.frame = frames.copyright
    }
}

#endif
