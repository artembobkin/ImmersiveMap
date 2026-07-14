// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Minimal TileJSON model. We only need the `tiles` array; the ImmersiveMap Tiles
/// service advertises a single versioned template such as
/// `https://host/v/<version>/tiles/{z}/{x}/{y}.pbf`, where the `<version>` segment
/// changes on every planet swap so the URL is immutable and CDN-cacheable.
struct TileJSONDocument: Decodable, Equatable {
    let tiles: [String]
}

/// Loads a TileJSON document and extracts its first tile URL template. The
/// injectable data loader mirrors `NightLightsTileSetMetadataLoader` so the
/// parsing can be unit-tested without hitting the network.
struct TileJSONTemplateLoader {
    private let loadData: (URL) async throws -> Data

    init(loadData: @escaping (URL) async throws -> Data = Self.loadData(from:)) {
        self.loadData = loadData
    }

    /// Returns the first tile URL template in the document, or `nil` when the
    /// document has no `tiles` entries.
    func loadTemplate(from url: URL) async throws -> String? {
        let data = try await loadData(url)
        let document = try JSONDecoder().decode(TileJSONDocument.self, from: data)
        return document.tiles.first
    }

    private static func loadData(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

/// Thread-safe holder for the resolved tile URL template. `nil` until the TileJSON
/// document is fetched (or if it never resolves), which is the signal for the
/// provider below to fall back to the static base-URL path.
final class TileJSONTemplateStore {
    private let stateQueue = DispatchQueue(label: "ImmersiveMap.TileJSONTemplateStore.state")
    private var storedTemplate: String?

    var template: String? {
        stateQueue.sync { storedTemplate }
    }

    func update(_ template: String?) {
        stateQueue.sync { storedTemplate = template }
    }
}

/// Tile URL provider that prefers a versioned TileJSON template
/// (`…/v/<version>/tiles/{z}/{x}/{y}.pbf`, cached hard by the CDN) and falls back
/// to a static base-URL provider until the template is resolved, or permanently
/// if the TileJSON document is unavailable. This keeps tiles flowing from the
/// first frame while transparently upgrading to the immutable, edge-cacheable
/// path once discovery completes.
final class TileJSONTileURLProvider: GetMapTileDownloadUrl {
    private let fallback: GetMapTileDownloadUrl
    private let store: TileJSONTemplateStore
    private let queryItemsProvider: (() -> [URLQueryItem])?

    init(fallback: GetMapTileDownloadUrl,
         store: TileJSONTemplateStore,
         queryItemsProvider: (() -> [URLQueryItem])? = nil) {
        self.fallback = fallback
        self.store = store
        self.queryItemsProvider = queryItemsProvider
    }

    func get(tileX: Int, tileY: Int, tileZ: Int) -> URL {
        if let template = store.template,
           let url = Self.url(fromTemplate: template,
                              x: tileX, y: tileY, z: tileZ,
                              queryItems: queryItemsProvider?() ?? []) {
            return url
        }
        return fallback.get(tileX: tileX, tileY: tileY, tileZ: tileZ)
    }

    /// Substitutes `{z}`/`{x}`/`{y}` into a TileJSON template and appends any query
    /// items (e.g. an API key). Returns `nil` for a malformed template so callers
    /// can fall back to the static path.
    static func url(fromTemplate template: String,
                    x: Int, y: Int, z: Int,
                    queryItems: [URLQueryItem]) -> URL? {
        let substituted = template
            .replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
        guard let url = URL(string: substituted) else {
            return nil
        }
        guard queryItems.isEmpty == false,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? url
    }
}
