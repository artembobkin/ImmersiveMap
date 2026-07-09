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
    let labelDetailTier: BaseLabelDetailTier

    var metalTileIdentity: ObjectIdentifier {
        ObjectIdentifier(metalTile)
    }

    static func build(from placeTiles: [PlaceTile],
                      center: Center,
                      centerZoom: Int,
                      renderSurfaceMode: ViewMode) -> [BaseLabelSourceEntry] {
        var bestEntryByOwnerKey: [VisibleTile: BaseLabelSourceEntry] = [:]
        bestEntryByOwnerKey.reserveCapacity(placeTiles.count)

        for placeTile in placeTiles {
            let labelDetailTier = makeLabelDetailTier(tile: placeTile.placeIn,
                                                      center: center,
                                                      centerZoom: centerZoom,
                                                      renderSurfaceMode: renderSurfaceMode)
            let entry = BaseLabelSourceEntry(ownerKey: VisibleTile(tile: placeTile.metalTile.tile,
                                                                   loop: placeTile.placeIn.loop),
                                             metalTile: placeTile.metalTile,
                                             isRetained: false,
                                             lodKind: placeTile.lodKind,
                                             labelDetailTier: labelDetailTier)
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

    static func build(from trackedPlaceTiles: [PlaceTileRetantionTracker.TrackedPlaceTile],
                      center: Center,
                      centerZoom: Int,
                      renderSurfaceMode: ViewMode) -> [BaseLabelSourceEntry] {
        var bestEntryByOwnerKey: [VisibleTile: BaseLabelSourceEntry] = [:]
        bestEntryByOwnerKey.reserveCapacity(trackedPlaceTiles.count)

        for trackedPlaceTile in trackedPlaceTiles {
            let labelDetailTier = makeLabelDetailTier(tile: trackedPlaceTile.placeTile.placeIn,
                                                      center: center,
                                                      centerZoom: centerZoom,
                                                      renderSurfaceMode: renderSurfaceMode)
            let entry = BaseLabelSourceEntry(ownerKey: VisibleTile(tile: trackedPlaceTile.placeTile.metalTile.tile,
                                                                   loop: trackedPlaceTile.placeTile.placeIn.loop),
                                             metalTile: trackedPlaceTile.placeTile.metalTile,
                                             isRetained: trackedPlaceTile.isRetained,
                                             lodKind: trackedPlaceTile.placeTile.lodKind,
                                             labelDetailTier: labelDetailTier)
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

    static func makeBaseLabelHash(_ sourceEntries: [BaseLabelSourceEntry]) -> Int {
        makeHash(sourceEntries, includesLabelDetailTier: true)
    }

    static func makeRoadLabelHash(_ sourceEntries: [BaseLabelSourceEntry]) -> Int {
        makeHash(sourceEntries, includesLabelDetailTier: false)
    }

    private static func makeHash(_ sourceEntries: [BaseLabelSourceEntry],
                                 includesLabelDetailTier: Bool) -> Int {
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
            if includesLabelDetailTier {
                hasher.combine(entry.labelDetailTier.rawValue)
            }
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

        if lhs.ownerKey == rhs.ownerKey {
            let lhsDetailRank = detailRank(for: lhs.labelDetailTier)
            let rhsDetailRank = detailRank(for: rhs.labelDetailTier)
            if lhsDetailRank != rhsDetailRank {
                return lhsDetailRank < rhsDetailRank
            }
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

    static func detailRank(for tier: BaseLabelDetailTier) -> Int {
        switch tier {
        case .full:
            return 0
        case .reduced:
            return 1
        case .minimal:
            return 2
        }
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

    private static func makeLabelDetailTier(tile: VisibleTile,
                                            center: Center,
                                            centerZoom: Int,
                                            renderSurfaceMode: ViewMode) -> BaseLabelDetailTier {
        let relativeDistance = BaseLabelDetailTier.relativeDistance(tile: tile,
                                                                    center: center,
                                                                    centerZoom: centerZoom,
                                                                    renderSurfaceMode: renderSurfaceMode)
        return BaseLabelDetailTier.tier(forRelativeDistance: relativeDistance)
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
