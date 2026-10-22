// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Map data source attribution: what a product using third-party data is
/// obligated to display. It belongs to the data, not the engine: the tile
/// source brings the tiles, so it knows whose data they are and under
/// which license they are served, and the engine adds the credit of the
/// data it ships itself (`OverviewTileSource`).
///
/// The badge is one line of credits along the map's edge, in the order
/// given, each one shown at the camera zooms its data is on screen at. A
/// data set that the map draws through a few zooms only, as the overview
/// of the globe, is credited at those zooms and not past them.
///
/// The data's credits are what the licenses require. The engine's own,
/// `engineCredit`, opens the line by default as a courtesy the MIT
/// license does not ask for, and goes with
/// `AttributionSettings.showsEngineCredit`.
public struct ImmersiveMapAttribution: Equatable, Sendable {
    /// One credit on the line.
    public struct Credit: Equatable, Sendable {
        /// The words, as the data's license asks for them.
        public var text: String

        /// The camera zooms the credited data is on screen at, a half-open
        /// range of camera zoom (`0..<8` is zoom 0 up to, not including, 8).
        /// Nil shows the credit at every zoom. The badge drops the credit
        /// outside the range, so a credit is shown where its data is and
        /// not where the map draws none of it.
        public var zoomRange: Range<Double>?

        public init(_ text: String, zoomRange: Range<Double>? = nil) {
            self.text = text
            self.zoomRange = zoomRange
        }

        /// Whether the credit shows at a camera zoom. An unknown zoom (nil,
        /// before the camera is placed) shows every credit: the safe side
        /// of a license.
        public func isShown(atZoom zoom: Double?) -> Bool {
            guard let zoom, let zoomRange else {
                return true
            }
            return zoomRange.contains(zoom)
        }
    }

    /// The credits, in the order they are shown on the line.
    public var credits: [Credit]

    /// Where a tap on the badge leads. Usually the data source's license page.
    public var linkURL: URL?

    public init(credits: [Credit], linkURL: URL? = nil) {
        self.credits = credits
        self.linkURL = linkURL
    }

    /// One credit for every zoom, the common case of one data source.
    public init(_ text: String, linkURL: URL? = nil) {
        self.init(credits: [Credit(text)], linkURL: linkURL)
    }

    /// No words to show at any zoom.
    public var isEmpty: Bool {
        credits.allSatisfy { $0.text.isEmpty }
    }

    /// The credits with words that show at a camera zoom, in order.
    public func credits(atZoom zoom: Double?) -> [Credit] {
        credits.filter { $0.text.isEmpty == false && $0.isShown(atZoom: zoom) }
    }

    /// The attribution with a credit added at the end of the line.
    public func appending(_ credit: Credit) -> ImmersiveMapAttribution {
        var attribution = self
        attribution.credits.append(credit)
        return attribution
    }

    /// Empty attribution: the badge draws nothing. The default for sources
    /// whose data source is unknown to the engine. If such a source serves OSM
    /// or other data that requires attribution, its author must set it.
    public static let none = ImmersiveMapAttribution(credits: [])

    /// The engine's own credit, the first on the default badge's line
    /// (`ImmersiveMapSettings.resolvedAttribution`). A courtesy, not a
    /// license term: `AttributionSettings.showsEngineCredit` drops it.
    public static let engineCredit = Credit("Powered by ImmersiveMap")

    /// Minimal attribution for OpenStreetMap data (ODbL).
    public static let openStreetMap = ImmersiveMapAttribution(
        "© OpenStreetMap contributors",
        linkURL: URL(string: "https://www.openstreetmap.org/copyright")
    )
}
