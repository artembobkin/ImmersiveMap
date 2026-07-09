// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum GlobeAtlasSlotDepth: UInt8, CaseIterable, Comparable, Hashable {
    case depth0 = 0
    case depth1 = 1
    case depth2 = 2
    case depth3 = 3
    case depth4 = 4

    static func < (lhs: GlobeAtlasSlotDepth, rhs: GlobeAtlasSlotDepth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func cellSize(pageSizePx: Int) -> Int {
        pageSizePx / (1 << Int(rawValue))
    }

    var largerSlotDepth: GlobeAtlasSlotDepth? {
        guard rawValue > GlobeAtlasSlotDepth.depth0.rawValue else {
            return nil
        }
        return GlobeAtlasSlotDepth(rawValue: rawValue - 1)
    }

    var areaUnitsAtMaximumDepth: Int {
        let maximumDepth = Int(GlobeAtlasSlotDepth.depth4.rawValue)
        let depthDelta = maximumDepth - Int(rawValue)
        return 1 << (depthDelta * 2)
    }

    static func desired(forScreenDemandPx screenDemandPx: Float,
                        pageSizePx: Int,
                        qualityScale: Float = 1.0) -> GlobeAtlasSlotDepth {
        let demand = max(1.0, screenDemandPx * max(0.25, qualityScale))
        for depth in GlobeAtlasSlotDepth.allCases.reversed() {
            if Float(depth.cellSize(pageSizePx: pageSizePx)) >= demand {
                return depth
            }
        }
        return .depth0
    }
}

struct GlobeAtlasCandidate: Hashable {
    let placementIndex: Int
    let placeTile: PlaceTile
    let screenDemandPx: Float
    let distanceToCamera: Float
    let desiredDepth: GlobeAtlasSlotDepth

    var isFallback: Bool {
        placeTile.isReplacement()
    }
}

struct GlobeAtlasAllocation: Hashable {
    let candidate: GlobeAtlasCandidate
    let pageIndex: Int
    let placedPosition: PlacedPos
    let atlasDepth: GlobeAtlasSlotDepth
    let cellSizePx: Int

    var placeTile: PlaceTile {
        candidate.placeTile
    }
}

struct GlobeAtlasPageSummary: Equatable {
    let pageIndex: Int
    let allocatedSlotCount: Int
}

struct GlobeAtlasPlan: Equatable {
    let allocations: [GlobeAtlasAllocation]
    let pageSummaries: [GlobeAtlasPageSummary]
    let downgradedAllocationCount: Int
    let skippedAllocationCount: Int

    static let empty = GlobeAtlasPlan(allocations: [],
                                      pageSummaries: [],
                                      downgradedAllocationCount: 0,
                                      skippedAllocationCount: 0)
}

struct GlobeAtlasDebugAllocation: Equatable {
    let pageIndex: Int
    let slotColumn: Int
    let slotRow: Int
    let slotsPerSide: Int
    let cellSizePx: Int
    let atlasDepth: GlobeAtlasSlotDepth
    let sourceTile: Tile
    let targetTile: Tile
    let screenDemandPx: Float
    let lodKind: TileLodKind
    let isFallback: Bool

    init(pageIndex: Int,
         slotColumn: Int,
         slotRow: Int,
         slotsPerSide: Int,
         cellSizePx: Int,
         atlasDepth: GlobeAtlasSlotDepth,
         sourceTile: Tile,
         targetTile: Tile,
         screenDemandPx: Float,
         lodKind: TileLodKind = .exact,
         isFallback: Bool) {
        self.pageIndex = pageIndex
        self.slotColumn = slotColumn
        self.slotRow = slotRow
        self.slotsPerSide = slotsPerSide
        self.cellSizePx = cellSizePx
        self.atlasDepth = atlasDepth
        self.sourceTile = sourceTile
        self.targetTile = targetTile
        self.screenDemandPx = screenDemandPx
        self.lodKind = lodKind
        self.isFallback = isFallback
    }

    init(allocation: GlobeAtlasAllocation) {
        let candidate = allocation.candidate
        pageIndex = allocation.pageIndex
        slotColumn = Int(allocation.placedPosition.x)
        slotRow = Int(allocation.placedPosition.y)
        slotsPerSide = 1 << Int(allocation.atlasDepth.rawValue)
        cellSizePx = allocation.cellSizePx
        atlasDepth = allocation.atlasDepth
        sourceTile = candidate.placeTile.metalTile.tile
        targetTile = candidate.placeTile.placeIn.tile
        screenDemandPx = candidate.screenDemandPx
        lodKind = candidate.placeTile.lodKind
        isFallback = candidate.isFallback
    }

    var atlasPreviewLabel: String {
        "z\(targetTile.z)/\(targetTile.x)/\(targetTile.y)"
    }
}

struct GlobeAtlasDebugPage: Equatable {
    let pageIndex: Int
    let allocations: [GlobeAtlasDebugAllocation]
}

struct GlobeAtlasDebugSummary: Equatable {
    let pageCount: Int
    let allocationCount: Int
    let downgradedAllocationCount: Int
    let skippedAllocationCount: Int
    let slotCountsByDepth: [GlobeAtlasSlotDepth: Int]
    let pages: [GlobeAtlasDebugPage]

    init(plan: GlobeAtlasPlan) {
        pageCount = plan.pageSummaries.count
        allocationCount = plan.allocations.count
        downgradedAllocationCount = plan.downgradedAllocationCount
        skippedAllocationCount = plan.skippedAllocationCount

        slotCountsByDepth = Dictionary(grouping: plan.allocations, by: \.atlasDepth)
            .mapValues(\.count)
        pages = Dictionary(grouping: plan.allocations.map(GlobeAtlasDebugAllocation.init), by: \.pageIndex)
            .map { GlobeAtlasDebugPage(pageIndex: $0.key,
                                       allocations: $0.value.sorted(by: Self.shouldPlaceDebugAllocationBefore)) }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    func slotCount(depth: GlobeAtlasSlotDepth) -> Int {
        slotCountsByDepth[depth] ?? 0
    }

    private static func shouldPlaceDebugAllocationBefore(_ lhs: GlobeAtlasDebugAllocation,
                                                         _ rhs: GlobeAtlasDebugAllocation) -> Bool {
        if lhs.atlasDepth != rhs.atlasDepth {
            return lhs.atlasDepth < rhs.atlasDepth
        }
        if lhs.slotRow != rhs.slotRow {
            return lhs.slotRow < rhs.slotRow
        }
        return lhs.slotColumn < rhs.slotColumn
    }
}
