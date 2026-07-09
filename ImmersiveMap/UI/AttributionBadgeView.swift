// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

/// Рендерит компактный attribution overlay.
/// Владеет только labels, styling и layout badge; состояние карты остается в surrounding runtimes.
final class AttributionBadgeView: UIView {
    private enum Layout {
        static let containerInset: CGFloat = 12
        static let horizontalInset: CGFloat = 10
        static let verticalInset: CGFloat = 7
        static let interLabelSpacing: CGFloat = 2
        static let maximumWidth: CGFloat = 240
    }

    private let titleLabel = UILabel()
    private let copyrightLabel = UILabel()
    private var linkURL: URL?

    convenience init(settings: ImmersiveMapSettings.AttributionSettings) {
        self.init(frame: .zero)
        apply(settings)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = UIColor.black.withAlphaComponent(0.56)
        layer.cornerRadius = 8
        layer.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.82

        copyrightLabel.font = .systemFont(ofSize: 10, weight: .regular)
        copyrightLabel.textColor = UIColor.white.withAlphaComponent(0.76)
        copyrightLabel.lineBreakMode = .byTruncatingTail
        copyrightLabel.adjustsFontSizeToFitWidth = true
        copyrightLabel.minimumScaleFactor = 0.82

        addSubview(titleLabel)
        addSubview(copyrightLabel)

        addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                    action: #selector(handleTap)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ settings: ImmersiveMapSettings.AttributionSettings) {
        isHidden = settings.isVisible == false
        linkURL = settings.linkURL
        isUserInteractionEnabled = settings.linkURL != nil
        accessibilityTraits = settings.linkURL == nil ? [] : [.link]
        titleLabel.text = settings.title
        copyrightLabel.text = settings.copyright
        setNeedsLayout()
    }

    @objc private func handleTap() {
        guard let linkURL else {
            return
        }

        UIApplication.shared.open(linkURL)
    }

    func layout(in bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        let availableWidth = max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right - Layout.containerInset * 2)
        let badgeSize = sizeThatFits(CGSize(width: availableWidth,
                                            height: bounds.height))
        frame = CGRect(
            x: bounds.width - safeAreaInsets.right - Layout.containerInset - badgeSize.width,
            y: bounds.height - safeAreaInsets.bottom - Layout.containerInset - badgeSize.height,
            width: badgeSize.width,
            height: badgeSize.height
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard isHidden == false else {
            return .zero
        }

        let maximumTextWidth = min(Layout.maximumWidth, size.width) - Layout.horizontalInset * 2
        let constrainedSize = CGSize(width: max(0, maximumTextWidth), height: .greatestFiniteMagnitude)
        let titleSize = titleLabel.sizeThatFits(constrainedSize)
        let copyrightSize = copyrightLabel.sizeThatFits(constrainedSize)
        let textWidth = max(titleSize.width, copyrightSize.width)
        let width = min(size.width, ceil(textWidth + Layout.horizontalInset * 2))
        let height = ceil(titleSize.height
                          + copyrightSize.height
                          + Layout.interLabelSpacing
                          + Layout.verticalInset * 2)

        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

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
