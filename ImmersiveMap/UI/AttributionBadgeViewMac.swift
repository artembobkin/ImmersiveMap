// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit

/// Рендерит компактный attribution overlay (AppKit).
/// Владеет только labels, styling и layout badge; состояние карты остается в surrounding runtimes.
final class AttributionBadgeView: NSView {
    private enum Layout {
        static let containerInset: CGFloat = 12
        static let horizontalInset: CGFloat = 10
        static let verticalInset: CGFloat = 7
        static let interLabelSpacing: CGFloat = 2
        static let maximumWidth: CGFloat = 240
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let copyrightLabel = NSTextField(labelWithString: "")
    private var linkURL: URL?

    override var isFlipped: Bool { true }

    convenience init(settings: ImmersiveMapSettings.AttributionSettings) {
        self.init(frame: .zero)
        apply(settings)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.56).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        copyrightLabel.font = .systemFont(ofSize: 10, weight: .regular)
        copyrightLabel.textColor = NSColor.white.withAlphaComponent(0.76)
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

    /// Без ссылки бейдж прозрачен для кликов - они уходят карте.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard linkURL != nil else {
            return nil
        }

        return super.hitTest(point)
    }

    func apply(_ settings: ImmersiveMapSettings.AttributionSettings) {
        isHidden = settings.isVisible == false
        linkURL = settings.linkURL
        titleLabel.stringValue = settings.title
        copyrightLabel.stringValue = settings.copyright
        needsLayout = true
    }

    @objc private func handleClick() {
        guard let linkURL else {
            return
        }

        NSWorkspace.shared.open(linkURL)
    }

    func layout(in bounds: CGRect, safeAreaInsets: NSEdgeInsets) {
        let availableWidth = max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right - Layout.containerInset * 2)
        let badgeSize = badgeSizeThatFits(CGSize(width: availableWidth,
                                                 height: bounds.height))
        frame = CGRect(
            x: bounds.width - safeAreaInsets.right - Layout.containerInset - badgeSize.width,
            y: bounds.height - safeAreaInsets.bottom - Layout.containerInset - badgeSize.height,
            width: badgeSize.width,
            height: badgeSize.height
        )
    }

    private func badgeSizeThatFits(_ size: CGSize) -> CGSize {
        guard isHidden == false else {
            return .zero
        }

        let maximumTextWidth = min(Layout.maximumWidth, size.width) - Layout.horizontalInset * 2
        let constrainedSize = CGSize(width: max(0, maximumTextWidth), height: .greatestFiniteMagnitude)
        let titleSize = titleLabel.sizeThatFits(constrainedSize)
        let copyrightSize = copyrightLabel.sizeThatFits(constrainedSize)
        let textWidth = max(min(titleSize.width, constrainedSize.width),
                            min(copyrightSize.width, constrainedSize.width))
        let width = min(size.width, ceil(textWidth + Layout.horizontalInset * 2))
        let height = ceil(titleSize.height
                          + copyrightSize.height
                          + Layout.interLabelSpacing
                          + Layout.verticalInset * 2)

        return CGSize(width: width, height: height)
    }

    override func layout() {
        super.layout()

        let textFrame = bounds.insetBy(dx: Layout.horizontalInset, dy: Layout.verticalInset)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textFrame.width,
                                                         height: .greatestFiniteMagnitude)).height
        let copyrightHeight = copyrightLabel.sizeThatFits(CGSize(width: textFrame.width,
                                                                 height: .greatestFiniteMagnitude)).height

        titleLabel.frame = CGRect(x: textFrame.minX,
                                  y: textFrame.minY,
                                  width: textFrame.width,
                                  height: titleHeight)
        copyrightLabel.frame = CGRect(x: textFrame.minX,
                                      y: titleLabel.frame.maxY + Layout.interLabelSpacing,
                                      width: textFrame.width,
                                      height: copyrightHeight)
    }
}

#endif
