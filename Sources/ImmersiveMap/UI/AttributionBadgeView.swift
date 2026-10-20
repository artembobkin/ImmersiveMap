// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

import UIKit

/// Renders the compact attribution overlay: one line of plain bold text
/// along the map's edge, no plate, each glyph in a dark halo that fades
/// out around it so the words read on any map colour underneath. The line
/// holds the credits shown at the camera's zoom
/// (`ImmersiveMapAttribution.credits(atZoom:)`), set the same way in the
/// settings' colour with a dot between them, or the first one bold and
/// the rest a shade dimmer (`AttributionSettings.emphasizesLeadingCredit`).
/// Owns only the badge label, styling, and layout; map state stays in the
/// surrounding runtimes. Size, position and text color come from
/// `AttributionSettings`; the geometry lives in `AttributionBadgeLayoutMath`.
final class AttributionBadgeView: UIView {
    /// The halo around every glyph: a dark shadow on the glyph itself,
    /// blurred by this many points, so its edge fades into the map rather
    /// than ends in a hard line, which a stroke on glyphs this small draws
    /// ragged.
    static let haloBlurRadius: CGFloat = 3.5
    static let haloColor = UIColor.black.withAlphaComponent(0.95)

    private let label = UILabel()
    private var attribution = ImmersiveMapAttribution.none
    private var settings = ImmersiveMapSettings.AttributionSettings()
    private var zoom: Double?
    /// The credits on the line, to tell a camera move that changes the
    /// line from the many that do not.
    private var shownCredits: [ImmersiveMapAttribution.Credit] = []
    private var linkURL: URL?
    private var metrics = AttributionBadgeLayoutMath.metrics(for: .regular)
    private var position = ImmersiveMapSettings.AttributionSettings.Position.bottomTrailing
    private var margin: CGFloat = 0
    /// The last layout the runtime asked for, so a zoom that changes the
    /// line can lay the badge out again without waiting for the next pass.
    private var lastLayout: (bounds: CGRect, safeAreaInsets: UIEdgeInsets)?

    convenience init(attribution: ImmersiveMapAttribution,
                     settings: ImmersiveMapSettings.AttributionSettings) {
        self.init(frame: .zero)
        apply(attribution, settings: settings)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear

        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.82
        addSubview(label)

        addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                    action: #selector(handleTap)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The credits and the look. Empty attribution hides the badge
    /// entirely: no point drawing an empty badge.
    func apply(_ attribution: ImmersiveMapAttribution,
               settings: ImmersiveMapSettings.AttributionSettings) {
        self.attribution = attribution
        self.settings = settings
        metrics = AttributionBadgeLayoutMath.metrics(for: settings.size)
        position = settings.position
        margin = CGFloat(settings.margin)
        linkURL = attribution.linkURL
        isUserInteractionEnabled = attribution.linkURL != nil
        accessibilityTraits = attribution.linkURL == nil ? [] : [.link]
        render()
    }

    /// The camera's zoom, on every move. The line changes only when a
    /// credit's zoom range is crossed, and then the badge is laid out again
    /// at once.
    func apply(zoom: Double?) {
        self.zoom = zoom
        guard attribution.credits(atZoom: zoom) != shownCredits else {
            return
        }
        render()
        if let lastLayout {
            layout(in: lastLayout.bounds, safeAreaInsets: lastLayout.safeAreaInsets)
        }
    }

    private func render() {
        shownCredits = attribution.credits(atZoom: zoom)
        isHidden = settings.isVisible == false || shownCredits.isEmpty
        label.attributedText = Self.lineText(credits: shownCredits,
                                             fontSize: metrics.fontSize,
                                             color: settings.textColor ?? SIMD4<Float>(1, 1, 1, 1),
                                             emphasizesLeading: settings.emphasizesLeadingCredit)
        setNeedsLayout()
    }

    /// The line: every credit and the dots between them in the semibold
    /// face at the colour's own alpha, one list. With `emphasizesLeading`
    /// the first credit is bold and the rest of the line a shade dimmer
    /// (`dimmedCreditAlpha`), so the tile source's credit leads the rest.
    static func lineText(credits: [ImmersiveMapAttribution.Credit],
                         fontSize: CGFloat,
                         color: SIMD4<Float>,
                         emphasizesLeading: Bool = false) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let restAlpha = emphasizesLeading ? dimmedCreditAlpha : 1
        for (index, credit) in credits.enumerated() {
            if index > 0 {
                line.append(haloText(AttributionBadgeLayoutMath.creditSeparator,
                                     font: .systemFont(ofSize: fontSize, weight: .semibold),
                                     color: color,
                                     alpha: restAlpha))
            }
            let leads = emphasizesLeading && index == 0
            line.append(haloText(credit.text,
                                 font: .systemFont(ofSize: fontSize, weight: leads ? .bold : .semibold),
                                 color: color,
                                 alpha: leads ? 1 : restAlpha))
        }
        return line
    }

    /// The share of the colour's alpha the credits behind a leading one
    /// are drawn at.
    static let dimmedCreditAlpha: CGFloat = 0.76

    /// The text filled in the settings' colour in a dark halo that fades
    /// out around every glyph, which is what keeps it legible over water,
    /// forest or a dark palette alike without a plate behind it.
    static func haloText(_ text: String, font: UIFont, color: SIMD4<Float>, alpha: CGFloat) -> NSAttributedString {
        let fill = UIColor(red: CGFloat(color.x),
                           green: CGFloat(color.y),
                           blue: CGFloat(color.z),
                           alpha: CGFloat(color.w) * alpha)
        let halo = NSShadow()
        halo.shadowOffset = .zero
        halo.shadowBlurRadius = haloBlurRadius
        halo.shadowColor = haloColor.withAlphaComponent(haloColor.cgColor.alpha * alpha)
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: fill,
            .shadow: halo
        ])
    }

    @objc private func handleTap() {
        guard let linkURL else {
            return
        }

        UIApplication.shared.open(linkURL)
    }

    func layout(in bounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        lastLayout = (bounds, safeAreaInsets)
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
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard isHidden == false else {
            return .zero
        }

        let maximumTextWidth = max(0, size.width - metrics.horizontalInset * 2)
        let textSize = label.sizeThatFits(CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude))

        return AttributionBadgeLayoutMath.badgeSize(textSize: textSize,
                                                    metrics: metrics,
                                                    boundingWidth: size.width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = AttributionBadgeLayoutMath.labelFrame(badgeBounds: bounds, metrics: metrics)
    }
}

#endif
