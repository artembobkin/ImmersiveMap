// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

/// Renders the compact attribution overlay.
/// Owns only the badge labels, styling, and layout; map state stays in the
/// surrounding runtimes. Size, position and text color come from
/// `AttributionSettings`; the geometry lives in `AttributionBadgeLayoutMath`.
final class AttributionBadgeView: UIView {
    private let titleLabel = UILabel()
    private let copyrightLabel = UILabel()
    private var linkURL: URL?
    private var metrics = AttributionBadgeLayoutMath.metrics(for: .regular)
    private var position = ImmersiveMapSettings.AttributionSettings.Position.bottomTrailing
    private var margin: CGFloat = 0

    convenience init(attribution: ImmersiveMapAttribution,
                     settings: ImmersiveMapSettings.AttributionSettings) {
        self.init(frame: .zero)
        apply(attribution, settings: settings)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = UIColor.black.withAlphaComponent(0.56)
        layer.masksToBounds = true

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.82

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

    /// Empty attribution hides the badge entirely: no point drawing an empty plate.
    /// An empty copyright collapses the second line: a one-line badge, no gap.
    func apply(_ attribution: ImmersiveMapAttribution,
               settings: ImmersiveMapSettings.AttributionSettings) {
        metrics = AttributionBadgeLayoutMath.metrics(for: settings.size)
        position = settings.position
        margin = CGFloat(settings.margin)
        isHidden = settings.isVisible == false || attribution.isEmpty
        linkURL = attribution.linkURL
        isUserInteractionEnabled = attribution.linkURL != nil
        accessibilityTraits = attribution.linkURL == nil ? [] : [.link]
        titleLabel.text = attribution.title
        copyrightLabel.text = attribution.copyright
        copyrightLabel.isHidden = attribution.copyright.isEmpty
        titleLabel.font = .systemFont(ofSize: metrics.titleFontSize, weight: .semibold)
        copyrightLabel.font = .systemFont(ofSize: metrics.copyrightFontSize, weight: .regular)
        layer.cornerRadius = metrics.cornerRadius
        applyTextColor(settings.textColor)
        setNeedsLayout()
    }

    private func applyTextColor(_ textColor: SIMD4<Float>?) {
        let color = textColor ?? SIMD4<Float>(1, 1, 1, 1)
        titleLabel.textColor = UIColor(red: CGFloat(color.x),
                                       green: CGFloat(color.y),
                                       blue: CGFloat(color.z),
                                       alpha: CGFloat(color.w))
        copyrightLabel.textColor = UIColor(red: CGFloat(color.x),
                                           green: CGFloat(color.y),
                                           blue: CGFloat(color.z),
                                           alpha: CGFloat(color.w) * 0.76)
    }

    @objc private func handleTap() {
        guard let linkURL else {
            return
        }

        UIApplication.shared.open(linkURL)
    }

    func layout(in bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        let availableWidth = AttributionBadgeLayoutMath.availableWidth(bounds: bounds,
                                                                       safeAreaInsets: safeAreaInsets,
                                                                       margin: margin)
        let badgeSize = sizeThatFits(CGSize(width: availableWidth,
                                            height: bounds.height))
        frame = AttributionBadgeLayoutMath.badgeFrame(
            badgeSize: badgeSize,
            position: position,
            bounds: bounds,
            safeAreaInsets: safeAreaInsets,
            margin: margin,
            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        layer.maskedCorners = Self.cornerMask(
            for: AttributionBadgeLayoutMath.roundedCorners(badgeFrame: frame, bounds: bounds))
    }

    private static func cornerMask(for rounded: AttributionBadgeLayoutMath.RoundedCorners) -> CACornerMask {
        var mask: CACornerMask = []
        if rounded.topLeft { mask.insert(.layerMinXMinYCorner) }
        if rounded.topRight { mask.insert(.layerMaxXMinYCorner) }
        if rounded.bottomLeft { mask.insert(.layerMinXMaxYCorner) }
        if rounded.bottomRight { mask.insert(.layerMaxXMaxYCorner) }
        return mask
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
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

    override func layoutSubviews() {
        super.layoutSubviews()

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
