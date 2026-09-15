// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The frame's placements as the label subsystems read them.
struct PlaceTileTrackingState {
    nonisolated(unsafe) static let empty = PlaceTileTrackingState(placeTiles: [])

    let placeTiles: [PlaceTile]

    init(placeTiles: [PlaceTile]) {
        self.placeTiles = placeTiles
    }
}
