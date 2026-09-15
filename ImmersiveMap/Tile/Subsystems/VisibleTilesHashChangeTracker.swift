// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  VisibleTilesHashChangeTracker.swift
//  ImmersiveMap
//

import Foundation

/// Tracks hash updates for visible tiles and exposes
/// a single boolean for expensive visible-tile resort work.
final class VisibleTilesHashChangeTracker {
    private var hashTracker = StagedHashChangeTracker()

    func shouldResortVisibleTiles(visibleTilesHash: Int) -> Bool {
        let hasChanges = hashTracker.stage(visibleTilesHash)
        if hasChanges {
            hashTracker.commitPending()
        }
        return hasChanges
    }

    func invalidate() {
        hashTracker.invalidate()
    }
}
