// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

protocol GetMapTileDownloadUrl {
    func get(tileX: Int, tileY: Int, tileZ: Int) -> URL
}
