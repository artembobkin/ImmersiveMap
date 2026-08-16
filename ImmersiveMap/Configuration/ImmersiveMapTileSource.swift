// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

public struct ImmersiveMapTileSource: Equatable, Sendable {
    public var tileBaseURL: URL
    /// Optional TileJSON endpoint. When set, the loader discovers a versioned,
    /// immutable tile URL template from it (…/v/<version>/tiles/{z}/{x}/{y}.pbf)
    /// and falls back to `tileBaseURL/{z}/{x}/{y}.mvt` until/if it resolves.
    public var tileJSONURL: URL?
    /// Optional tile URL template with `{x}`, `{y}` and `{z}` placeholders, e.g.
    /// `https://tiles.com/{x}/{y}/{z}?apiKey=xxx`. When set, it wins over both
    /// `tileBaseURL` (which the loader would otherwise extend with
    /// `/{z}/{x}/{y}.mvt`) and TileJSON discovery. The query string is part of
    /// the template, so a key embedded there travels with every request.
    public var urlTemplate: String?
    /// HTTP header fields added to every tile request, e.g.
    /// `["X-API-Key": "xxx"]` or `["Authorization": "Bearer xxx"]`. This is how
    /// header-based credentials travel. Assumed not to change the tile bytes:
    /// header names are part of the cache identity, header values are not, so
    /// rotating a credential keeps the caches warm. A header whose value
    /// selects different content needs a provider fingerprint bump.
    public var headers: [String: String]

    public init(tileBaseURL: URL,
                tileJSONURL: URL? = nil,
                urlTemplate: String? = nil,
                headers: [String: String] = [:]) {
        self.tileBaseURL = tileBaseURL
        self.tileJSONURL = tileJSONURL
        self.urlTemplate = urlTemplate
        self.headers = headers
    }

    public static func url(_ tileBaseURL: URL) -> ImmersiveMapTileSource {
        ImmersiveMapTileSource(tileBaseURL: tileBaseURL)
    }

    /// A source described entirely by a URL template such as
    /// `https://tiles.com/{x}/{y}/{z}?apiKey=xxx`. All three placeholders are
    /// required; they may appear in any order and the query string is preserved.
    /// `headers` are added to every tile request.
    public static func template(_ urlTemplate: String,
                                headers: [String: String] = [:]) -> ImmersiveMapTileSource {
        assert(urlTemplate.contains("{x}") && urlTemplate.contains("{y}") && urlTemplate.contains("{z}"),
               "A tile URL template needs {x}, {y} and {z} placeholders: \(urlTemplate)")
        // The legacy base URL is never used for requests while the template is
        // set; it only needs to be a stable, valid URL for identity and logs.
        let substituted = urlTemplate
            .replacingOccurrences(of: "{x}", with: "0")
            .replacingOccurrences(of: "{y}", with: "0")
            .replacingOccurrences(of: "{z}", with: "0")
        let tileBaseURL = URL(string: substituted) ?? URL(string: "https://invalid.invalid")!
        return ImmersiveMapTileSource(tileBaseURL: tileBaseURL,
                                      urlTemplate: urlTemplate,
                                      headers: headers)
    }

    /// Returns a copy with the given HTTP header fields added to every tile
    /// request (replacing same-named fields set earlier).
    public func headers(_ headers: [String: String]) -> ImmersiveMapTileSource {
        var source = self
        source.headers = source.headers.merging(headers) { _, new in new }
        return source
    }
}
