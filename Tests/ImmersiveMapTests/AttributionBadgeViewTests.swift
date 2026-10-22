// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if canImport(UIKit)

@testable import ImmersiveMap
import UIKit
import XCTest

@MainActor
final class AttributionBadgeViewTests: XCTestCase {
    private let boundingSize = CGSize(width: 400, height: 400)

    private func lineText(of view: AttributionBadgeView) -> NSAttributedString? {
        view.subviews.compactMap { $0 as? UILabel }.first?.attributedText
    }

    func testDefaultAttributionBadgeIsInteractive() {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        settings: settings.attribution)

        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertFalse(view.isHidden)
    }

    /// No plate behind the words: the badge is one line of text, each
    /// glyph in a dark halo so it reads on any map colour underneath.
    func testTheBadgeIsOneLineOfPlainTextInAHaloForAnyBackground() throws {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        settings: settings.attribution)

        XCTAssertEqual(view.backgroundColor, .clear, "Nothing is painted behind the text")
        XCTAssertEqual(view.subviews.compactMap { $0 as? UILabel }.count, 1, "One line")
        let line = try XCTUnwrap(lineText(of: view))
        XCTAssertEqual(line.string, "© OpenStreetMap · Biomes © RESOLVE, CC BY 4.0 · © Mapterhorn",
                       "Before the camera is placed every credit shows")
        let attributes = line.attributes(at: 0, effectiveRange: nil)
        let halo = try XCTUnwrap(attributes[.shadow] as? NSShadow)
        XCTAssertEqual(halo.shadowBlurRadius, AttributionBadgeView.haloBlurRadius)
        XCTAssertNotNil(attributes[.foregroundColor] as? UIColor)
    }

    /// The overview's credit is on the line at the zooms the overview is
    /// drawn at and off it past them, and the badge narrows with the line.
    func testACreditLeavesTheLineWithTheZoom() throws {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        settings: settings.attribution)

        view.apply(zoom: 3)
        XCTAssertEqual(lineText(of: view)?.string, "© OpenStreetMap · Biomes © RESOLVE, CC BY 4.0")
        let widthWithOverview = view.sizeThatFits(boundingSize).width

        view.apply(zoom: 12.2)
        XCTAssertEqual(lineText(of: view)?.string, "© OpenStreetMap · © Mapterhorn", "The terrain's credit at the zooms the relief rises at")
        XCTAssertLessThan(view.sizeThatFits(boundingSize).width, widthWithOverview)

        view.apply(zoom: 7.9)
        XCTAssertEqual(lineText(of: view)?.string, "© OpenStreetMap · Biomes © RESOLVE, CC BY 4.0")
    }

    func testEmptyAttributionHidesBadge() {
        let view = AttributionBadgeView(attribution: .none,
                                        settings: ImmersiveMapSettings.AttributionSettings())

        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.isUserInteractionEnabled)
    }

    /// A line whose every credit has left at a zoom hides the badge, and
    /// a credit coming back shows it again.
    func testTheBadgeHidesWhenNoCreditShowsAtTheZoom() {
        let view = AttributionBadgeView(attribution: ImmersiveMapAttribution(credits: [.init("© Low", zoomRange: 0..<5)]),
                                        settings: ImmersiveMapSettings.AttributionSettings())

        view.apply(zoom: 9)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.sizeThatFits(boundingSize), .zero)

        view.apply(zoom: 2)
        XCTAssertFalse(view.isHidden)
    }

    /// Two credits make a longer line, not a taller badge.
    func testASecondCreditWidensTheLine() {
        let one = AttributionBadgeView(
            attribution: ImmersiveMapAttribution("© Data"),
            settings: ImmersiveMapSettings.AttributionSettings()
        )
        let two = AttributionBadgeView(
            attribution: ImmersiveMapAttribution(credits: [.init("© Data"), .init("© More data")]),
            settings: ImmersiveMapSettings.AttributionSettings()
        )

        let oneSize = one.sizeThatFits(boundingSize)
        let twoSize = two.sizeThatFits(boundingSize)

        XCTAssertGreaterThan(oneSize.height, 0)
        XCTAssertEqual(twoSize.height, oneSize.height)
        XCTAssertGreaterThan(twoSize.width, oneSize.width)
    }

    /// Size presets must order the rendered badge monotonically. The
    /// width is read in a frame wide enough for every credit at every
    /// preset: a line cut at the frame's edge is the frame's width.
    func testSizePresetsScaleTheBadge() {
        func badgeSize(_ size: ImmersiveMapSettings.AttributionSettings.Size) -> CGSize {
            let settings = ImmersiveMapSettings.default
            let view = AttributionBadgeView(
                attribution: settings.resolvedAttribution,
                settings: ImmersiveMapSettings.AttributionSettings(size: size)
            )
            return view.sizeThatFits(CGSize(width: 1600, height: 400))
        }

        let small = badgeSize(.small)
        let regular = badgeSize(.regular)
        let large = badgeSize(.large)

        XCTAssertLessThan(small.height, regular.height)
        XCTAssertLessThan(regular.height, large.height)
        XCTAssertLessThan(small.width, regular.width)
        XCTAssertLessThan(regular.width, large.width)
    }
}

#endif
