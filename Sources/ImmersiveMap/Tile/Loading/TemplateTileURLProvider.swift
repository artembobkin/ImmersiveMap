// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Builds tile URLs from an app-supplied template such as
/// `https://tiles.com/{x}/{y}/{z}?apiKey=xxx`. Unlike the TileJSON provider,
/// whose template arrives from the network after discovery, this one is fixed
/// configuration: the substitution is the same, only the origin of the
/// template differs. The fallback covers a template malformed enough that no
/// valid URL comes out of it, so a bad string degrades to the legacy base
/// path instead of crashing the loader.
final class TemplateTileURLProvider: GetMapTileDownloadUrl {
    private let template: String
    private let fallback: GetMapTileDownloadUrl

    init(template: String, fallback: GetMapTileDownloadUrl) {
        self.template = template
        self.fallback = fallback
    }

    func get(tileX: Int, tileY: Int, tileZ: Int) -> URL {
        // Foundation's lenient parser percent-encodes almost any string into
        // *some* URL, so parsing alone proves nothing; an absolute URL with a
        // host is what separates a template from a typo.
        if let url = TileJSONTileURLProvider.url(fromTemplate: template, x: tileX, y: tileY, z: tileZ),
           url.scheme != nil, url.host != nil {
            return url
        }
        return fallback.get(tileX: tileX, tileY: tileY, tileZ: tileZ)
    }
}
