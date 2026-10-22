// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

@testable import ImmersiveMap
import AppKit
import XCTest

/// The AppKit badge, the same line as UIKit's: the credits shown at the
/// camera's zoom, one after the other.
@MainActor
final class AttributionBadgeViewMacTests: XCTestCase {
    private let boundingSize = CGSize(width: 400, height: 400)

    private func lineText(of view: AttributionBadgeView) -> String? {
        view.subviews.compactMap { $0 as? NSTextField }.first?.attributedStringValue.string
    }

    /// One line, every credit on it before the camera is placed, the
    /// terrain's included, each glyph in a dark halo.
    func testTheBadgeIsOneLineOfCredits() throws {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        settings: settings.attribution)

        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.subviews.compactMap { $0 as? NSTextField }.count, 1, "One line")
        XCTAssertEqual(lineText(of: view), "© OpenStreetMap · Biomes © RESOLVE, CC BY 4.0 · © Mapterhorn · Powered by ImmersiveMap")
        let line = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first?.attributedStringValue)
        let halo = try XCTUnwrap(line.attributes(at: 0, effectiveRange: nil)[.shadow] as? NSShadow)
        XCTAssertEqual(halo.shadowBlurRadius, AttributionBadgeView.haloBlurRadius)
    }

    /// By default every credit is set the same way, one list. With
    /// `emphasizesLeadingCredit` the first is bold at full strength and
    /// the rest a shade dimmer.
    func testTheCreditsAreOneListUnlessTheFirstIsAskedToLead() throws {
        let credits = ImmersiveMapSettings.default.resolvedAttribution.credits(atZoom: nil)
        XCTAssertGreaterThanOrEqual(credits.count, 2)
        func attributes(_ line: NSAttributedString, _ index: Int) -> (weight: NSFont.Weight?, alpha: CGFloat) {
            let attributes = line.attributes(at: index, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let weight = (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
            let color = attributes[.foregroundColor] as? NSColor
            return (weight.map { NSFont.Weight(rawValue: $0) }, color?.alphaComponent ?? -1)
        }
        let list = AttributionBadgeView.lineText(credits: credits, fontSize: 11, color: SIMD4<Float>(1, 1, 1, 1))
        let secondStart = credits[0].text.count + AttributionBadgeLayoutMath.creditSeparator.count
        XCTAssertEqual(attributes(list, 0).alpha, attributes(list, secondStart).alpha, "The same alpha")
        XCTAssertEqual(attributes(list, 0).weight, attributes(list, secondStart).weight, "The same face")
        XCTAssertEqual(attributes(list, 0).alpha, 1, accuracy: 0.001, "Solid: the colour's own alpha")
        let translucent = AttributionBadgeView.lineText(credits: credits, fontSize: 11, color: SIMD4<Float>(1, 1, 1, 0.5))
        XCTAssertEqual(attributes(translucent, 0).alpha, 0.5, accuracy: 0.001, "A translucent badge is a colour with an alpha")

        let led = AttributionBadgeView.lineText(credits: credits, fontSize: 11, color: SIMD4<Float>(1, 1, 1, 1),
                                                emphasizesLeading: true)
        XCTAssertEqual(attributes(led, 0).alpha, 1, accuracy: 0.001, "The first at full strength")
        XCTAssertEqual(attributes(led, secondStart).alpha, AttributionBadgeView.dimmedCreditAlpha, accuracy: 0.001)
        XCTAssertNotEqual(attributes(led, 0).weight, attributes(led, secondStart).weight, "and bold")
    }

    /// The overview's credit is on the line at the zooms the overview is
    /// drawn at and off it past them, where the terrain's takes its place
    /// at the zooms the relief rises at, and the badge narrows with the
    /// line.
    func testACreditLeavesTheLineWithTheZoom() {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        settings: settings.attribution)

        view.apply(zoom: 3)
        XCTAssertEqual(lineText(of: view), "© OpenStreetMap · Biomes © RESOLVE, CC BY 4.0 · Powered by ImmersiveMap")
        let widthWithOverview = view.badgeSizeThatFits(boundingSize).width

        view.apply(zoom: 12.2)
        XCTAssertEqual(lineText(of: view), "© OpenStreetMap · © Mapterhorn · Powered by ImmersiveMap")
        XCTAssertLessThan(view.badgeSizeThatFits(boundingSize).width, widthWithOverview)

        view.apply(zoom: 7.9)
        XCTAssertEqual(lineText(of: view), "© OpenStreetMap · Biomes © RESOLVE, CC BY 4.0 · Powered by ImmersiveMap")
    }

    /// A zoom that changes the line lays the badge out again where the
    /// runtime last put it, so the line does not wait for the next layout
    /// pass to shrink or grow.
    func testAZoomThatChangesTheLineLaysTheBadgeOutAgain() {
        let settings = ImmersiveMapSettings.default
        let view = AttributionBadgeView(attribution: settings.resolvedAttribution,
                                        settings: settings.attribution)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.apply(zoom: 3)
        view.layout(in: bounds, safeAreaInsets: NSEdgeInsets())
        let frameWithOverview = view.frame

        view.apply(zoom: 12)

        XCTAssertLessThan(view.frame.width, frameWithOverview.width)
        XCTAssertEqual(view.frame.maxX, bounds.maxX, "Still pinned to its corner")
        XCTAssertEqual(view.frame.maxY, bounds.maxY)
    }

    /// A line whose every credit has left at a zoom hides the badge, and
    /// a credit coming back shows it again.
    func testTheBadgeHidesWhenNoCreditShowsAtTheZoom() {
        let view = AttributionBadgeView(attribution: ImmersiveMapAttribution(credits: [.init("© Low", zoomRange: 0..<5)]),
                                        settings: ImmersiveMapSettings.AttributionSettings())

        view.apply(zoom: 9)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.badgeSizeThatFits(boundingSize), .zero)

        view.apply(zoom: 2)
        XCTAssertFalse(view.isHidden)
    }

    /// Two credits make a longer line, not a taller badge.
    func testASecondCreditWidensTheLine() {
        let one = AttributionBadgeView(attribution: ImmersiveMapAttribution("© Data"),
                                       settings: ImmersiveMapSettings.AttributionSettings())
        let two = AttributionBadgeView(attribution: ImmersiveMapAttribution(credits: [.init("© Data"), .init("© More data")]),
                                       settings: ImmersiveMapSettings.AttributionSettings())

        let oneSize = one.badgeSizeThatFits(boundingSize)
        let twoSize = two.badgeSizeThatFits(boundingSize)

        XCTAssertGreaterThan(oneSize.height, 0)
        XCTAssertEqual(twoSize.height, oneSize.height)
        XCTAssertGreaterThan(twoSize.width, oneSize.width)
    }
}

#endif
