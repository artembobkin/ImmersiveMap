// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum TileAtlasSlotDepth: UInt8, CaseIterable, Comparable, Hashable {
    case depth0 = 0
    case depth1 = 1
    case depth2 = 2
    case depth3 = 3
    case depth4 = 4

    static func < (lhs: TileAtlasSlotDepth, rhs: TileAtlasSlotDepth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func cellSize(pageSizePx: Int) -> Int {
        pageSizePx / (1 << Int(rawValue))
    }

    var largerSlotDepth: TileAtlasSlotDepth? {
        guard rawValue > TileAtlasSlotDepth.depth0.rawValue else {
            return nil
        }
        return TileAtlasSlotDepth(rawValue: rawValue - 1)
    }

    var areaUnitsAtMaximumDepth: Int {
        let maximumDepth = Int(TileAtlasSlotDepth.depth4.rawValue)
        let depthDelta = maximumDepth - Int(rawValue)
        return 1 << (depthDelta * 2)
    }

    static func desired(forScreenDemandPx screenDemandPx: Float,
                        pageSizePx: Int,
                        qualityScale: Float = 1.0) -> TileAtlasSlotDepth {
        let demand = max(1.0, screenDemandPx * max(0.25, qualityScale))
        for depth in TileAtlasSlotDepth.allCases.reversed() {
            if Float(depth.cellSize(pageSizePx: pageSizePx)) >= demand {
                return depth
            }
        }
        return .depth0
    }
}

struct TileAtlasCandidate: Hashable {
    let placementIndex: Int
    let placeTile: PlaceTile
    let screenDemandPx: Float
    let distanceToCamera: Float
    let desiredDepth: TileAtlasSlotDepth

    var isFallback: Bool {
        placeTile.isReplacement()
    }
}

struct TileAtlasAllocation: Hashable {
    let candidate: TileAtlasCandidate
    let pageIndex: Int
    let placedPosition: PlacedPos
    let atlasDepth: TileAtlasSlotDepth
    let cellSizePx: Int

    var placeTile: PlaceTile {
        candidate.placeTile
    }

    /// Atlas texels per on-screen pixel for this slot, log-quantized to
    /// eighth-of-an-octave steps (about 9 percent).
    ///
    /// Point-locked line widths bake into the atlas in texels, but the baked
    /// page is then magnified on screen by the fractional-zoom dolly, which
    /// the bake cannot see: converting points to texels through this ratio is
    /// what keeps the on-screen width steady while the camera closes in, and
    /// continuous across an integer zoom (the demand halves exactly as the
    /// next level's tiles take over, so the products cancel). Quantized so
    /// the value can sit in the atlas redraw hash without re-baking every
    /// frame: a step costs one redraw, and a sub-step drift of a few percent
    /// of a line's width is invisible. Clamped, so a degenerate footprint
    /// cannot demand an absurd bake width.
    var lineWidthRasterScale: Float {
        Self.lineWidthRasterScale(cellSizePx: cellSizePx,
                                  screenDemandPx: candidate.screenDemandPx)
    }

    static func lineWidthRasterScale(cellSizePx: Int, screenDemandPx: Float) -> Float {
        let raw = Float(cellSizePx) / max(screenDemandPx, 1.0)
        let clamped = min(max(raw, 0.25), 4.0)
        let stepped = (log2(clamped) * 8.0).rounded() / 8.0
        return exp2(stepped)
    }
}

struct TileAtlasPageSummary: Equatable {
    let pageIndex: Int
    let allocatedSlotCount: Int
}

struct TileAtlasPlan: Equatable {
    let allocations: [TileAtlasAllocation]
    let pageSummaries: [TileAtlasPageSummary]
    let downgradedAllocationCount: Int
    let skippedAllocationCount: Int

    nonisolated(unsafe) static let empty = TileAtlasPlan(allocations: [],
                                      pageSummaries: [],
                                      downgradedAllocationCount: 0,
                                      skippedAllocationCount: 0)
}

struct TileAtlasDebugAllocation: Equatable {
    let pageIndex: Int
    let slotColumn: Int
    let slotRow: Int
    let slotsPerSide: Int
    let cellSizePx: Int
    let atlasDepth: TileAtlasSlotDepth
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
         atlasDepth: TileAtlasSlotDepth,
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

    init(allocation: TileAtlasAllocation) {
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

struct TileAtlasDebugPage: Equatable {
    let pageIndex: Int
    let allocations: [TileAtlasDebugAllocation]
}

struct TileAtlasDebugSummary: Equatable {
    let pageCount: Int
    let allocationCount: Int
    let downgradedAllocationCount: Int
    let skippedAllocationCount: Int
    let slotCountsByDepth: [TileAtlasSlotDepth: Int]
    let pages: [TileAtlasDebugPage]

    init(plan: TileAtlasPlan) {
        pageCount = plan.pageSummaries.count
        allocationCount = plan.allocations.count
        downgradedAllocationCount = plan.downgradedAllocationCount
        skippedAllocationCount = plan.skippedAllocationCount

        slotCountsByDepth = Dictionary(grouping: plan.allocations, by: \.atlasDepth)
            .mapValues(\.count)
        pages = Dictionary(grouping: plan.allocations.map(TileAtlasDebugAllocation.init), by: \.pageIndex)
            .map { TileAtlasDebugPage(pageIndex: $0.key,
                                       allocations: $0.value.sorted(by: Self.shouldPlaceDebugAllocationBefore)) }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    func slotCount(depth: TileAtlasSlotDepth) -> Int {
        slotCountsByDepth[depth] ?? 0
    }

    private static func shouldPlaceDebugAllocationBefore(_ lhs: TileAtlasDebugAllocation,
                                                         _ rhs: TileAtlasDebugAllocation) -> Bool {
        if lhs.atlasDepth != rhs.atlasDepth {
            return lhs.atlasDepth < rhs.atlasDepth
        }
        if lhs.slotRow != rhs.slotRow {
            return lhs.slotRow < rhs.slotRow
        }
        return lhs.slotColumn < rhs.slotColumn
    }
}
