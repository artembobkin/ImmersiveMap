// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

class BackendTileURLProvider: GetMapTileDownloadUrl {
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func get(tileX: Int, tileY: Int, tileZ: Int) -> URL {
        baseURL
            .appendingPathComponent("\(tileZ)")
            .appendingPathComponent("\(tileX)")
            .appendingPathComponent("\(tileY).mvt")
    }
}
