// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelSourceEntry.swift
//  ImmersiveMap
//

import Foundation

struct BaseLabelSourceEntry {
    let ownerKey: VisibleTile
    let metalTile: MetalTile
    let isRetained: Bool
    let lodKind: TileLodKind

    var metalTileIdentity: ObjectIdentifier {
        ObjectIdentifier(metalTile)
    }

    static func build(from placeTiles: [PlaceTile]) -> [BaseLabelSourceEntry] {
        var bestEntryByOwnerKey: [VisibleTile: BaseLabelSourceEntry] = [:]
        bestEntryByOwnerKey.reserveCapacity(placeTiles.count)

        for placeTile in placeTiles {
            let entry = BaseLabelSourceEntry(ownerKey: VisibleTile(tile: placeTile.metalTile.tile,
                                                                   loop: placeTile.placeIn.loop),
                                             metalTile: placeTile.metalTile,
                                             isRetained: false,
                                             lodKind: placeTile.lodKind)
            if let existingEntry = bestEntryByOwnerKey[entry.ownerKey] {
                if preferredWinner(lhs: entry, rhs: existingEntry) {
                    bestEntryByOwnerKey[entry.ownerKey] = entry
                }
            } else {
                bestEntryByOwnerKey[entry.ownerKey] = entry
            }
        }

        return bestEntryByOwnerKey.values.sorted(by: sortForWinnerPriority(lhs:rhs:))
    }

    static func build(from trackedPlaceTiles: [PlaceTileRetantionTracker.TrackedPlaceTile]) -> [BaseLabelSourceEntry] {
        var bestEntryByOwnerKey: [VisibleTile: BaseLabelSourceEntry] = [:]
        bestEntryByOwnerKey.reserveCapacity(trackedPlaceTiles.count)

        for trackedPlaceTile in trackedPlaceTiles {
            let entry = BaseLabelSourceEntry(ownerKey: VisibleTile(tile: trackedPlaceTile.placeTile.metalTile.tile,
                                                                   loop: trackedPlaceTile.placeTile.placeIn.loop),
                                             metalTile: trackedPlaceTile.placeTile.metalTile,
                                             isRetained: trackedPlaceTile.isRetained,
                                             lodKind: trackedPlaceTile.placeTile.lodKind)
            if let existingEntry = bestEntryByOwnerKey[entry.ownerKey] {
                if preferredWinner(lhs: entry, rhs: existingEntry) {
                    bestEntryByOwnerKey[entry.ownerKey] = entry
                }
            } else {
                bestEntryByOwnerKey[entry.ownerKey] = entry
            }
        }

        return bestEntryByOwnerKey.values.sorted(by: sortForWinnerPriority(lhs:rhs:))
    }

    /// The identity of the frame's source set: which tiles, in which
    /// slots, by which parsed objects. The base and the road label caches
    /// both rebuild when it changes.
    static func makeHash(_ sourceEntries: [BaseLabelSourceEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(sourceEntries.count)
        for entry in sourceEntries {
            let ownerKey = entry.ownerKey
            hasher.combine(priorityRank(for: entry))
            hasher.combine(ownerKey.x)
            hasher.combine(ownerKey.y)
            hasher.combine(ownerKey.z)
            hasher.combine(ownerKey.loop)
            hasher.combine(entry.isRetained)
            hasher.combine(entry.lodKind.rawValue)
            hasher.combine(entry.metalTile.tile.x)
            hasher.combine(entry.metalTile.tile.y)
            hasher.combine(entry.metalTile.tile.z)
            hasher.combine(entry.metalTileIdentity)
        }
        return hasher.finalize()
    }

    static func sortForWinnerPriority(lhs: BaseLabelSourceEntry, rhs: BaseLabelSourceEntry) -> Bool {
        let lhsPriority = priorityRank(for: lhs)
        let rhsPriority = priorityRank(for: rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if lhs.ownerKey.z != rhs.ownerKey.z {
            return lhs.ownerKey.z > rhs.ownerKey.z
        }
        if lhs.ownerKey.x != rhs.ownerKey.x {
            return lhs.ownerKey.x < rhs.ownerKey.x
        }
        if lhs.ownerKey.y != rhs.ownerKey.y {
            return lhs.ownerKey.y < rhs.ownerKey.y
        }
        return lhs.ownerKey.loop < rhs.ownerKey.loop
    }

    private static func preferredWinner(lhs: BaseLabelSourceEntry, rhs: BaseLabelSourceEntry) -> Bool {
        if sortForWinnerPriority(lhs: lhs, rhs: rhs) {
            return true
        }
        if sortForWinnerPriority(lhs: rhs, rhs: lhs) {
            return false
        }
        return false
    }

    static func priorityRank(for entry: BaseLabelSourceEntry) -> Int {
        switch (entry.lodKind == .exact, entry.isRetained) {
        case (true, false):
            return 0
        case (true, true):
            return 1
        case (false, false):
            return 2
        case (false, true):
            return 3
        }
    }
}
