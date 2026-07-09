// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct TileParseLayerTiming: Equatable {
    let layerName: String
    let duration: TimeInterval
}

struct PreparedTileLoadResult {
    let preparedTile: PreparedTileCPU
    let parseLayerTimings: [TileParseLayerTiming]
}
