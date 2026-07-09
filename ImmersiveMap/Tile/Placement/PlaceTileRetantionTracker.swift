// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

final class PlaceTileRetantionTracker {
    struct TrackedPlaceTile {
        let placeTile: PlaceTile
        let isRetained: Bool

        init(placeTile: PlaceTile,
             isRetained: Bool) {
            self.placeTile = placeTile
            self.isRetained = isRetained
        }

        init(visibleTile: VisibleTile,
             lodKind: TileLodKind,
             isRetained: Bool,
             metalTile: MetalTile) {
            self.placeTile = PlaceTile(metalTile: metalTile,
                                       placeIn: visibleTile,
                                       lodKind: lodKind)
            self.isRetained = isRetained
        }

        var visibleTile: VisibleTile { placeTile.placeIn }
        var lodKind: TileLodKind { placeTile.lodKind }
        var metalTile: MetalTile? { placeTile.metalTile }
    }

    struct UpdateResult {
        let trackedPlaceTiles: [TrackedPlaceTile]
        let retainedCount: Int
        let hasChanges: Bool

        init(trackedPlaceTiles: [TrackedPlaceTile],
             retainedCount: Int,
             hasChanges: Bool = false) {
            self.trackedPlaceTiles = trackedPlaceTiles
            self.retainedCount = retainedCount
            self.hasChanges = hasChanges
        }
    }

    private struct Entry {
        var lastSeen: TimeInterval
        var isRetained: Bool
        var placeTile: PlaceTile
        var seenGeneration: UInt64
    }

    private struct RetainedCandidate {
        let visibleTile: VisibleTile
        let lastSeen: TimeInterval
        let placeTile: PlaceTile
    }

    private let holdSeconds: TimeInterval
    private var entries: [VisibleTile: Entry] = [:]
    private var updateGeneration: UInt64 = 0
    private var trackedPlaceTilesHashTracker = StagedHashChangeTracker()

    init(holdSeconds: TimeInterval) {
        self.holdSeconds = holdSeconds
    }

    func update(placedTiles: [PlaceTile], now: TimeInterval) -> UpdateResult {
        incrementUpdateGeneration()

        var trackedPlaceTiles: [TrackedPlaceTile] = []
        trackedPlaceTiles.reserveCapacity(placedTiles.count + entries.count)

        var hasher = Hasher()
        hasher.combine(placedTiles.count)

        for placedTile in placedTiles {
            let visibleTile = placedTile.placeIn
            if var existingEntry = entries[visibleTile] {
                existingEntry.lastSeen = now
                existingEntry.isRetained = false
                existingEntry.placeTile = placedTile
                existingEntry.seenGeneration = updateGeneration
                entries[visibleTile] = existingEntry
            } else {
                entries[visibleTile] = Entry(lastSeen: now,
                                             isRetained: false,
                                             placeTile: placedTile,
                                             seenGeneration: updateGeneration)
            }

            let retainedPlaceTile = TrackedPlaceTile(placeTile: placedTile,
                                                      isRetained: false)
            trackedPlaceTiles.append(retainedPlaceTile)
            combineTrackedPlaceTileHash(retainedPlaceTile, into: &hasher)
        }

        let activeSourceVisibleTiles = makeActiveSourceVisibleTiles(from: placedTiles)
        var retainedCandidates: [RetainedCandidate] = []
        retainedCandidates.reserveCapacity(entries.count)

        let knownTiles = Array(entries.keys)
        for tile in knownTiles {
            guard var entry = entries[tile] else {
                continue
            }

            if entry.seenGeneration == updateGeneration {
                continue
            }

            if now - entry.lastSeen > holdSeconds {
                entries.removeValue(forKey: tile)
                continue
            }

            // Do not retain a stale visible placement when the same source tile is
            // already actively reused by a current-frame placement in the same loop.
            // Downstream label pipelines treat retained tiles as fade-out candidates,
            // so keeping the stale exact placement here would incorrectly hide labels
            // for an active replacement.
            if activeSourceVisibleTiles.contains(tile) {
                continue
            }

            if entry.isRetained == false {
                entry.isRetained = true
                entries[tile] = entry
            }

            retainedCandidates.append(RetainedCandidate(visibleTile: tile,
                                                        lastSeen: entry.lastSeen,
                                                        placeTile: entry.placeTile))
        }

        retainedCandidates.sort { lhs, rhs in
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen > rhs.lastSeen
            }
            if lhs.visibleTile.z != rhs.visibleTile.z {
                return lhs.visibleTile.z > rhs.visibleTile.z
            }
            if lhs.visibleTile.x != rhs.visibleTile.x {
                return lhs.visibleTile.x < rhs.visibleTile.x
            }
            if lhs.visibleTile.y != rhs.visibleTile.y {
                return lhs.visibleTile.y < rhs.visibleTile.y
            }
            return lhs.visibleTile.loop < rhs.visibleTile.loop
        }

        for retained in retainedCandidates {
            let retainedPlaceTile = TrackedPlaceTile(placeTile: retained.placeTile,
                                                      isRetained: true)
            trackedPlaceTiles.append(retainedPlaceTile)
            combineTrackedPlaceTileHash(retainedPlaceTile, into: &hasher)
        }

        hasher.combine(retainedCandidates.count)
        hasher.combine(trackedPlaceTiles.count)
        let trackedPlaceTilesHash = hasher.finalize()
        let hasChanges = trackedPlaceTilesHashTracker.stage(trackedPlaceTilesHash)
        if hasChanges {
            trackedPlaceTilesHashTracker.commitPending()
        }

        return UpdateResult(trackedPlaceTiles: trackedPlaceTiles,
                            retainedCount: retainedCandidates.count,
                            hasChanges: hasChanges)
    }

    private func makeActiveSourceVisibleTiles(from placedTiles: [PlaceTile]) -> Set<VisibleTile> {
        var sourceTiles: Set<VisibleTile> = []
        sourceTiles.reserveCapacity(placedTiles.count)
        for placedTile in placedTiles {
            sourceTiles.insert(VisibleTile(tile: placedTile.metalTile.tile,
                                           loop: placedTile.placeIn.loop))
        }
        return sourceTiles
    }

    private func incrementUpdateGeneration() {
        updateGeneration &+= 1
        if updateGeneration != 0 {
            return
        }

        updateGeneration = 1
        resetSeenGenerationMarkersAfterWraparound()
    }

    private func resetSeenGenerationMarkersAfterWraparound() {
        let allTiles = Array(entries.keys)
        for tile in allTiles {
            guard var entry = entries[tile] else {
                continue
            }
            entry.seenGeneration = 0
            entries[tile] = entry
        }
    }

    private func combineTrackedPlaceTileHash(_ retainedPlaceTile: TrackedPlaceTile, into hasher: inout Hasher) {
        let placeTile = retainedPlaceTile.placeTile
        hasher.combine(placeTile.placeIn.x)
        hasher.combine(placeTile.placeIn.y)
        hasher.combine(placeTile.placeIn.z)
        hasher.combine(placeTile.placeIn.loop)
        hasher.combine(placeTile.lodKind.rawValue)
        hasher.combine(retainedPlaceTile.isRetained)
        hasher.combine(ObjectIdentifier(placeTile.metalTile))
    }
}
