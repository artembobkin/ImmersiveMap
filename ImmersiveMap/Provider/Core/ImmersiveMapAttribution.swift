// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Map data source attribution: what a product using third-party tiles is
/// obligated to display. It belongs to the provider, not the engine: the
/// provider brings the tiles, so it knows whose data they are and under
/// which license they are served.
///
/// The engine never puts its own brand here: a map drawn on top of
/// OpenStreetMap data must credit OpenStreetMap, not the renderer.
public struct ImmersiveMapAttribution: Equatable, Sendable {
    /// First line of the badge: the tile source.
    public var title: String

    /// Second line of the badge: data copyrights.
    public var copyright: String

    /// Where a tap on the badge leads. Usually the data source's license page.
    public var linkURL: URL?

    public var isEmpty: Bool {
        title.isEmpty && copyright.isEmpty
    }

    public init(title: String, copyright: String, linkURL: URL? = nil) {
        self.title = title
        self.copyright = copyright
        self.linkURL = linkURL
    }

    /// Empty attribution: the badge draws nothing. The default for providers
    /// whose data source is unknown to the engine. If such a provider serves OSM
    /// or other data that requires attribution, the provider's author must set it.
    public static let none = ImmersiveMapAttribution(title: "", copyright: "")

    /// Minimal attribution for OpenStreetMap data (ODbL).
    public static let openStreetMap = ImmersiveMapAttribution(
        title: "© OpenStreetMap",
        copyright: "OpenStreetMap contributors",
        linkURL: URL(string: "https://www.openstreetmap.org/copyright")
    )
}
