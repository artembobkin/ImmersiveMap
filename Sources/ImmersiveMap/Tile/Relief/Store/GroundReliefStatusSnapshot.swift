// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What the terrain store holds and does at a moment
/// (`GroundReliefFrame.statusSnapshot()`), for the debug panel's relief tab:
/// every terrain tile the frame wants or the store keeps, and the totals.
package struct GroundReliefStatusSnapshot: Equatable {
    package enum State: Equatable {
        /// Wanted, waiting for a load slot.
        case queued
        case loading
        /// In memory, a texture and its heights on the CPU.
        case resident
        /// The last load failed, and waits out its pause before the next.
        case failed
    }

    package struct TileStatus: Equatable {
        package let tile: Tile
        package let state: State
        /// The tile's place in the frame's demand, nearest first from 0,
        /// nil for one kept from earlier frames.
        package let priority: Int?
        /// What it costs in memory, zero until it is in.
        package let bytes: Int
        /// Its lowest and highest heights in metres, once it is in.
        package let heightRange: ClosedRange<Float>?
        /// Seconds the load has run, or till the next attempt of a failed
        /// one.
        package let seconds: Int
        /// The failed attempts so far.
        package let attempts: Int

        package var isWanted: Bool { priority != nil }
    }

    /// The wanted tiles nearest first, then the ones kept from earlier
    /// frames, the coarse first.
    package let tiles: [TileStatus]
    /// The frame is on the terrain (`GroundReliefFrame.isActive`).
    package let isActive: Bool
    package let standingShare: Float
    package let datumMetres: Float
    package let cameraTerrainZoom: Int
    /// The terrain zoom of each ring's band, target zoom to terrain zoom
    /// (`GroundReliefTerrainZooms.statusText`).
    package let terrainByRing: String
    package let wantedCount: Int
    package let wantedResidentCount: Int
    package let residentCount: Int
    package let residentBytes: Int
    /// The tiles the frame stopped reading, kept for a frame that reads
    /// them again (`GroundReliefSettings.releasedCacheBytes`).
    package let releasedCount: Int
    package let releasedBytes: Int
    package let releasedCacheBytes: Int
    /// The tiles in whose occlusion of the sky is computed under the
    /// current key (`GroundReliefOcclusion`), and how long the last one
    /// took, in milliseconds.
    package let occlusionComputedCount: Int
    package let occlusionMillisecondsLast: Double
    package let loadingCount: Int
    package let maximumConcurrentLoads: Int
    package let failedCount: Int
    /// Tiles the source does not have, replaced by their ancestors.
    package let missingCount: Int
    /// The country around the camera as the frame read it
    /// (`FrameContext.terrainSurroundings`), set by the frame's snapshot,
    /// nil off the terrain or before the terrain under the camera is in.
    package var surroundings: ImmersiveMapTerrainSurroundings? = nil

    /// The frame on the terrain or off it, how far the relief has risen
    /// and the datum: the panel's Relief group, one value a line.
    package var stateLines: [String] {
        ["relief: \(isActive ? "on the terrain" : "off the terrain")",
         "standing \(String(format: "%.2f", standingShare))",
         "datum \(String(format: "%.0f", datumMetres)) m"]
    }

    /// What the frame wants and how the loads go: the panel's Terrain
    /// loading group.
    package var loadingLines: [String] {
        ["wanted \(wantedCount)",
         "wanted and in \(wantedResidentCount)",
         "loading \(loadingCount) of \(maximumConcurrentLoads)",
         "failed \(failedCount)",
         "missing \(missingCount)"]
    }

    /// What the store keeps and which maps it reads: the panel's Terrain
    /// memory group.
    package var memoryLines: [String] {
        let megabytes = { (bytes: Int) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        return ["in memory \(residentCount) tiles, \(megabytes(residentBytes)) MB",
                "released \(releasedCount) tiles, \(megabytes(releasedBytes)) of \(megabytes(releasedCacheBytes)) MB",
                "camera map z\(cameraTerrainZoom)",
                "terrain by ring \(terrainByRing.isEmpty ? "none" : terrainByRing)"]
    }

    /// The occlusion of the sky as computed: the panel's AO tab.
    package var occlusionLines: [String] {
        ["computed \(occlusionComputedCount) of \(residentCount) tiles",
         "last tile \(String(format: "%.1f", occlusionMillisecondsLast)) ms"]
    }

    /// The country around the camera as read: the panel's Surroundings
    /// group. "waiting for terrain" while the frame is on the terrain and
    /// the reading has not come, "off the terrain" otherwise.
    package var surroundingsLines: [String] {
        guard let surroundings else {
            return ["around: \(isActive ? "waiting for terrain" : "off the terrain")"]
        }
        return ["around: \(surroundings.kind.rawValue)",
                "span \(String(format: "%.0f", surroundings.heightSpanMetres)) m",
                "mountainousness \(String(format: "%.2f", surroundings.mountainousness))",
                "ground \(String(format: "%.0f", surroundings.groundMetres)) m"]
    }

    /// The panel's summary where it is one text (the iOS panel): every
    /// group's lines in turn.
    package var lines: [String] {
        stateLines + loadingLines + memoryLines + surroundingsLines
    }
}
