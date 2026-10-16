// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What the terrain store holds and does at a moment
/// (`GroundReliefStore.statusSnapshot()`), for the debug panel's relief tab:
/// every terrain tile the frame wants or the store keeps, and the totals.
struct GroundReliefStatusSnapshot: Equatable {
    enum State: Equatable {
        /// Wanted, waiting for a load slot.
        case queued
        case loading
        /// In memory, a texture and its heights on the CPU.
        case resident
        /// The last load failed, and waits out its pause before the next.
        case failed
    }

    struct TileStatus: Equatable {
        let tile: Tile
        let state: State
        /// The tile's place in the frame's demand, nearest first from 0,
        /// nil for one kept from earlier frames.
        let priority: Int?
        /// What it costs in memory, zero until it is in.
        let bytes: Int
        /// Its lowest and highest heights in metres, once it is in.
        let heightRange: ClosedRange<Float>?
        /// Seconds the load has run, or till the next attempt of a failed
        /// one.
        let seconds: Int
        /// The failed attempts so far.
        let attempts: Int

        var isWanted: Bool { priority != nil }
    }

    /// The wanted tiles nearest first, then the ones kept from earlier
    /// frames, the coarse first.
    let tiles: [TileStatus]
    /// The frame is on the terrain (`GroundReliefStore.isActive`).
    let isActive: Bool
    let standingShare: Float
    let datumMetres: Float
    let cameraTerrainZoom: Int
    /// Which terrain tiles the ground reads (`GroundReliefSettings.detail`).
    let detail: GroundReliefTerrainZooms.Detail
    let wantedCount: Int
    let wantedResidentCount: Int
    let residentCount: Int
    let residentBytes: Int
    let budgetBytes: Int
    let loadingCount: Int
    let maximumConcurrentLoads: Int
    let failedCount: Int
    /// Tiles the source does not have, replaced by their ancestors.
    let missingCount: Int

    /// The panel's summary, line by line.
    var lines: [String] {
        let megabytes = { (bytes: Int) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        return [
            "relief: \(isActive ? "on the terrain" : "off the terrain") standing \(String(format: "%.2f", standingShare)) datum \(String(format: "%.0f", datumMetres)) m",
            "wanted \(wantedCount) in \(wantedResidentCount) · loading \(loadingCount)/\(maximumConcurrentLoads) · failed \(failedCount) · missing \(missingCount)",
            "in memory \(residentCount) tiles \(megabytes(residentBytes)) / \(megabytes(budgetBytes)) MB · camera map z\(cameraTerrainZoom) · \(detail.rawValue)"
        ]
    }
}
