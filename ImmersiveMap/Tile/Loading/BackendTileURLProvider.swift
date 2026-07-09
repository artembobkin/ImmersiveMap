// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

class BackendTileURLProvider: GetMapTileDownloadUrl {
    private let baseURL: URL
    private let queryItemsProvider: (() -> [URLQueryItem])?

    init(baseURL: URL, queryItemsProvider: (() -> [URLQueryItem])? = nil) {
        self.baseURL = baseURL
        self.queryItemsProvider = queryItemsProvider
    }

    func get(tileX: Int, tileY: Int, tileZ: Int) -> URL {
        return tileURLFor(zoom: tileZ, x: tileX, y: tileY)
    }

    private func tileURLFor(zoom: Int, x: Int, y: Int) -> URL {
        baseURL
            .appendingPathComponent("\(zoom)")
            .appendingPathComponent("\(x)")
            .appendingPathComponent("\(y).mvt")
            .appendingQueryItems(queryItemsProvider?() ?? [])
    }
}

private extension URL {
    func appendingQueryItems(_ newQueryItems: [URLQueryItem]) -> URL {
        guard newQueryItems.isEmpty == false,
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }

        components.queryItems = (components.queryItems ?? []) + newQueryItems
        return components.url ?? self
    }
}
