// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The zoom badge in the map's top trailing corner, a part of the debug
/// panel (`DebugSettings.showsZoomBadge`): the camera's zoom and the
/// planning zoom, large enough to read at a glance while a gesture is under
/// way, quicker than the panel's camera line. Over the relief the two part
/// through a drag (`FrameContext.planningZoom`). Read off the panel's frame
/// snapshot, so it costs the frame nothing of its own, and hidden with the
/// panel and the map's controls (`ControlsSettings.isHidden`). Clicks and
/// touches go through it to the map.
enum DebugOverlayZoomBadge {
    /// The badge's lines: the camera's zoom, then the planning zoom.
    static func lines(zoom: Double, planningZoom: Double) -> [String] {
        [String(format: "z %.2f", zoom), String(format: "plan %.2f", planningZoom)]
    }

    static let fontSize: CGFloat = 22
    static let lineSpacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    static let backgroundAlpha: CGFloat = 0.55
    /// The distance from the map's top and trailing edges.
    static let margin: CGFloat = 16

    /// The badge's frame for its size, in the top trailing corner of
    /// `bounds` under `topInset`, in top-left origin coordinates.
    static func frame(size: CGSize, bounds: CGRect, topInset: CGFloat, isRightToLeft: Bool) -> CGRect {
        let x = isRightToLeft ? bounds.minX + margin : bounds.maxX - margin - size.width
        return CGRect(x: x, y: bounds.minY + topInset + margin, width: size.width, height: size.height)
    }
}

#if canImport(UIKit)

final class DebugOverlayZoomBadgeView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(DebugOverlayZoomBadge.backgroundAlpha)
        layer.cornerRadius = DebugOverlayZoomBadge.cornerRadius
        label.numberOfLines = 0
        label.textAlignment = .right
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: DebugOverlayZoomBadge.fontSize, weight: .semibold)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(zoom: Double, planningZoom: Double) {
        let text = DebugOverlayZoomBadge.lines(zoom: zoom, planningZoom: planningZoom).joined(separator: "\n")
        guard label.text != text else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = DebugOverlayZoomBadge.lineSpacing
        style.alignment = .right
        label.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: style])
        setNeedsLayout()
    }

    func layout(in bounds: CGRect, topInset: CGFloat) {
        let textSize = label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(textSize.width) + DebugOverlayZoomBadge.horizontalPadding * 2,
                          height: ceil(textSize.height) + DebugOverlayZoomBadge.verticalPadding * 2)
        frame = DebugOverlayZoomBadge.frame(size: size, bounds: bounds, topInset: topInset,
                                            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft)
        label.frame = self.bounds.insetBy(dx: DebugOverlayZoomBadge.horizontalPadding, dy: DebugOverlayZoomBadge.verticalPadding)
    }
}

#elseif os(macOS)

final class DebugOverlayZoomBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(DebugOverlayZoomBadge.backgroundAlpha).cgColor
        layer?.cornerRadius = DebugOverlayZoomBadge.cornerRadius
        label.maximumNumberOfLines = 0
        label.alignment = .right
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: DebugOverlayZoomBadge.fontSize, weight: .semibold)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks go through to the map.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func apply(zoom: Double, planningZoom: Double) {
        let text = DebugOverlayZoomBadge.lines(zoom: zoom, planningZoom: planningZoom).joined(separator: "\n")
        guard label.stringValue != text else { return }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = DebugOverlayZoomBadge.lineSpacing
        style.alignment = .right
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .paragraphStyle: style,
            .font: NSFont.monospacedSystemFont(ofSize: DebugOverlayZoomBadge.fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
    }

    func layout(in bounds: CGRect, topInset: CGFloat) {
        let textSize = label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(textSize.width) + DebugOverlayZoomBadge.horizontalPadding * 2,
                          height: ceil(textSize.height) + DebugOverlayZoomBadge.verticalPadding * 2)
        frame = DebugOverlayZoomBadge.frame(size: size, bounds: bounds, topInset: topInset,
                                            isRightToLeft: userInterfaceLayoutDirection == .rightToLeft)
        label.frame = self.bounds.insetBy(dx: DebugOverlayZoomBadge.horizontalPadding, dy: DebugOverlayZoomBadge.verticalPadding)
    }
}

#endif
