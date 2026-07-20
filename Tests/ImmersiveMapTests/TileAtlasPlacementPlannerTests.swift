// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import MetalKit
import XCTest

final class TileAtlasPlacementPlannerTests: XCTestCase {
    func testSlotDepthCellSizesUseFixed4096Page() {
        XCTAssertEqual(TileAtlasSlotDepth.depth0.cellSize(pageSizePx: 4096), 4096)
        XCTAssertEqual(TileAtlasSlotDepth.depth1.cellSize(pageSizePx: 4096), 2048)
        XCTAssertEqual(TileAtlasSlotDepth.depth2.cellSize(pageSizePx: 4096), 1024)
        XCTAssertEqual(TileAtlasSlotDepth.depth3.cellSize(pageSizePx: 4096), 512)
        XCTAssertEqual(TileAtlasSlotDepth.depth4.cellSize(pageSizePx: 4096), 256)
    }

    func testDesiredDepthRoundsScreenDemandUpToNextAvailableCell() {
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 2300, pageSizePx: 4096), .depth0)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 1600, pageSizePx: 4096), .depth1)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 900, pageSizePx: 4096), .depth2)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 420, pageSizePx: 4096), .depth3)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 90, pageSizePx: 4096), .depth4)
    }

    func testDesiredDepthClampsOversizedDemandToFullPageCell() {
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 4097, pageSizePx: 4096), .depth0)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 8000, pageSizePx: 4096), .depth0)
    }

    func testDesiredDepthKeepsExactBoundaryInCurrentCell() {
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 4096, pageSizePx: 4096), .depth0)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 2048, pageSizePx: 4096), .depth1)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 1024, pageSizePx: 4096), .depth2)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 512, pageSizePx: 4096), .depth3)
        XCTAssertEqual(TileAtlasSlotDepth.desired(forScreenDemandPx: 256, pageSizePx: 4096), .depth4)
    }

    func testSingleCandidateUpscalesToFullPageWithinExistingPageBudget() throws {
        let candidate = try makeCandidate(index: 0,
                                          source: Tile(x: 0, y: 0, z: 0),
                                          target: Tile(x: 0, y: 0, z: 0),
                                          screenDemandPx: 90,
                                          distanceToCamera: 0)

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [candidate])

        XCTAssertEqual(plan.allocations.map(\.atlasDepth), [.depth0])
        XCTAssertEqual(plan.pageSummaries.count, 1)
    }

    func testFourSmallCandidatesUpscaleWithoutCreatingNewPage() throws {
        let candidates = try (0..<4).map { index in
            try makeCandidate(index: index,
                              source: Tile(x: index % 2, y: index / 2, z: 1),
                              target: Tile(x: index % 2, y: index / 2, z: 1),
                              screenDemandPx: 90,
                              distanceToCamera: Float(index))
        }

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: candidates)

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.map(\.atlasDepth), Array(repeating: .depth1, count: 4))
        XCTAssertEqual(plan.pageSummaries.count, 1)
    }

    func testCandidatesUpscaleWithinSinglePageBudgetByDemandPriority() throws {
        let small = try makeCandidate(index: 0,
                                      source: Tile(x: 0, y: 0, z: 1),
                                      target: Tile(x: 0, y: 0, z: 1),
                                      screenDemandPx: 90,
                                      distanceToCamera: 1)
        let large = try makeCandidate(index: 1,
                                      source: Tile(x: 0, y: 0, z: 3),
                                      target: Tile(x: 0, y: 0, z: 3),
                                      screenDemandPx: 900,
                                      distanceToCamera: 0)

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [small, large])

        XCTAssertEqual(plan.allocations.map(\.candidate.placementIndex), [1, 0])
        XCTAssertEqual(plan.allocations.map(\.atlasDepth), [.depth1, .depth1])
        XCTAssertEqual(plan.pageSummaries.count, 1)
        XCTAssertEqual(plan.downgradedAllocationCount, 0)
    }

    func testPlannerKeepsAllocationStableAcrossSmallPriorityMetricJitter() throws {
        let planner = TileAtlasPlacementPlanner(pageSizePx: 4096)
        let firstFrameCandidates = try [
            makeCandidate(index: 0,
                          source: Tile(x: 4, y: 2, z: 5),
                          target: Tile(x: 4, y: 2, z: 5),
                          screenDemandPx: 300.1,
                          distanceToCamera: 0.11),
            makeCandidate(index: 1,
                          source: Tile(x: 5, y: 2, z: 5),
                          target: Tile(x: 5, y: 2, z: 5),
                          screenDemandPx: 310.2,
                          distanceToCamera: 0.13)
        ]
        let nextFrameCandidates = try [
            makeCandidate(index: 0,
                          source: Tile(x: 4, y: 2, z: 5),
                          target: Tile(x: 4, y: 2, z: 5),
                          screenDemandPx: 310.3,
                          distanceToCamera: 0.12),
            makeCandidate(index: 1,
                          source: Tile(x: 5, y: 2, z: 5),
                          target: Tile(x: 5, y: 2, z: 5),
                          screenDemandPx: 300.4,
                          distanceToCamera: 0.14)
        ]

        let firstPlan = planner.plan(candidates: firstFrameCandidates)
        let nextPlan = planner.plan(candidates: nextFrameCandidates)

        XCTAssertEqual(stableAllocationLayout(firstPlan),
                       stableAllocationLayout(nextPlan))
    }

    func testFallbackWithLargeFootprintGetsHighResolutionBeforeSmallExactTile() throws {
        let fallback = try makeCandidate(index: 0,
                                         source: Tile(x: 4, y: 2, z: 3),
                                         target: Tile(x: 17, y: 10, z: 5),
                                         screenDemandPx: 1700,
                                         distanceToCamera: 0.1)
        let exact = try makeCandidate(index: 1,
                                      source: Tile(x: 18, y: 10, z: 5),
                                      target: Tile(x: 18, y: 10, z: 5),
                                      screenDemandPx: 260,
                                      distanceToCamera: 0.2)

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [exact, fallback])

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.count, 2)
        XCTAssertEqual(plan.allocations[0].candidate.placementIndex, 0)
        XCTAssertEqual(plan.allocations[0].atlasDepth, .depth1)
        XCTAssertEqual(plan.allocations[0].cellSizePx, 2048)
        XCTAssertEqual(plan.allocations[1].candidate.placementIndex, 1)
        XCTAssertEqual(plan.allocations[1].atlasDepth, .depth1)
        XCTAssertEqual(plan.allocations[1].cellSizePx, 2048)
    }

    func testAllocatorCreatesSecondPageForMultipleFullPageDemands() throws {
        let first = try makeCandidate(index: 0,
                                      source: Tile(x: 0, y: 0, z: 2),
                                      target: Tile(x: 0, y: 0, z: 2),
                                      screenDemandPx: 3000,
                                      distanceToCamera: 0.0)
        let second = try makeCandidate(index: 1,
                                       source: Tile(x: 1, y: 0, z: 2),
                                       target: Tile(x: 1, y: 0, z: 2),
                                       screenDemandPx: 2800,
                                       distanceToCamera: 0.1)

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [first, second])

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.map(\.pageIndex), [0, 1])
        XCTAssertEqual(plan.allocations.map(\.atlasDepth), [.depth0, .depth0])
        XCTAssertEqual(plan.pageSummaries.count, 2)
    }

    func testAllocatorCreatesPagesForAllFullPageDemands() throws {
        let candidates = try (0..<16).map { index in
            try makeCandidate(index: index,
                              source: Tile(x: index, y: 0, z: 4),
                              target: Tile(x: index, y: 0, z: 4),
                              screenDemandPx: 3000,
                              distanceToCamera: Float(index))
        }

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: candidates)

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.count, 16)
        XCTAssertEqual(plan.pageSummaries.count, 16)
        XCTAssertEqual(plan.skippedAllocationCount, 0)
        XCTAssertEqual(plan.downgradedAllocationCount, 0)
        XCTAssertEqual(Set(plan.allocations.map(\.atlasDepth)), [.depth0])
    }

    func testAllocatorKeepsFullPageSlotsWhenCoverageAllowsIt() throws {
        let candidates = try (0..<3).map { index in
            try makeCandidate(index: index,
                              source: Tile(x: index, y: 0, z: 2),
                              target: Tile(x: index, y: 0, z: 2),
                              screenDemandPx: 3000,
                              distanceToCamera: Float(index))
        }

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: candidates)

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.count, 3)
        XCTAssertEqual(plan.skippedAllocationCount, 0)
        XCTAssertEqual(plan.allocations.map(\.atlasDepth), [.depth0, .depth0, .depth0])
    }

    func testAllocatorCreatesSecondPageForDepthOneDemandsInsteadOfDowngrading() throws {
        let candidates = try (0..<5).map { index in
            try makeCandidate(index: index,
                              source: Tile(x: index, y: 0, z: 4),
                              target: Tile(x: index, y: 0, z: 4),
                              screenDemandPx: 1500,
                              distanceToCamera: Float(index))
        }

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: candidates)

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.count, 5)
        XCTAssertEqual(plan.pageSummaries.count, 2)
        XCTAssertEqual(plan.allocations.map(\.atlasDepth), [.depth0, .depth1, .depth1, .depth1, .depth1])
        XCTAssertEqual(plan.downgradedAllocationCount, 0)
        XCTAssertEqual(plan.skippedAllocationCount, 0)
    }

    func testAllocatorCreatesSecondPageForFullPageDemandsInsteadOfDowngrading() throws {
        let first = try makeCandidate(index: 0,
                                      source: Tile(x: 0, y: 0, z: 2),
                                      target: Tile(x: 0, y: 0, z: 2),
                                      screenDemandPx: 3000,
                                      distanceToCamera: 0.0)
        let second = try makeCandidate(index: 1,
                                       source: Tile(x: 1, y: 0, z: 2),
                                       target: Tile(x: 1, y: 0, z: 2),
                                       screenDemandPx: 2800,
                                       distanceToCamera: 0.1)

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [first, second])

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.count, 2)
        XCTAssertEqual(plan.allocations.map(\.pageIndex), [0, 1])
        XCTAssertEqual(plan.allocations.map(\.atlasDepth), [.depth0, .depth0])
        XCTAssertEqual(plan.downgradedAllocationCount, 0)
        XCTAssertEqual(plan.skippedAllocationCount, 0)
    }

    func testTileAtlasDebugSummaryCountsPagesSlotsAndHighResolutionFallbacks() throws {
        let candidates = try [
            makeCandidate(index: 0,
                          source: Tile(x: 4, y: 4, z: 3),
                          target: Tile(x: 16, y: 16, z: 5),
                          screenDemandPx: 1500,
                          distanceToCamera: 0.0),
            makeCandidate(index: 1,
                          source: Tile(x: 1, y: 0, z: 4),
                          target: Tile(x: 1, y: 0, z: 4),
                          screenDemandPx: 1500,
                          distanceToCamera: 1.0),
            makeCandidate(index: 2,
                          source: Tile(x: 2, y: 0, z: 4),
                          target: Tile(x: 2, y: 0, z: 4),
                          screenDemandPx: 1500,
                          distanceToCamera: 2.0),
            makeCandidate(index: 3,
                          source: Tile(x: 3, y: 0, z: 4),
                          target: Tile(x: 3, y: 0, z: 4),
                          screenDemandPx: 1500,
                          distanceToCamera: 3.0),
            makeCandidate(index: 4,
                          source: Tile(x: 4, y: 0, z: 4),
                          target: Tile(x: 4, y: 0, z: 4),
                          screenDemandPx: 1500,
                          distanceToCamera: 4.0)
        ]
        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: candidates)

        let summary = TileAtlasDebugSummary(plan: plan)

        XCTAssertEqual(summary.pageCount, 2)
        XCTAssertEqual(summary.allocationCount, 5)
        XCTAssertEqual(summary.downgradedAllocationCount, 0)
        XCTAssertEqual(summary.skippedAllocationCount, 0)
        XCTAssertEqual(summary.slotCount(depth: .depth0), 1)
        XCTAssertEqual(summary.slotCount(depth: .depth1), 4)
        XCTAssertEqual(RendererDebugOverlayDrawer.makeAtlasDebugLines(summary: summary), [
            "atlas pages:2 alloc:5 down:0 skip:0",
            "atlas d0:1 d1:4 d2:0 d3:0 d4:0"
        ])
    }

    func testAllocatorExpandsBeyondFormerMaximumDepthFourCapacityWithoutSkips() throws {
        let candidates = try (0..<769).map { index in
            try makeCandidate(index: index,
                              source: Tile(x: index, y: 0, z: 10),
                              target: Tile(x: index, y: 0, z: 10),
                              screenDemandPx: 90,
                              distanceToCamera: Float(index))
        }

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: candidates)

        XCTAssertEqual(plan.allocations.count, 769)
        XCTAssertEqual(plan.skippedAllocationCount, 0)
        XCTAssertEqual(plan.downgradedAllocationCount, 0)
        XCTAssertEqual(plan.pageSummaries.count, 4)
        XCTAssertEqual(Set(plan.allocations.map(\.atlasDepth)), [.depth0, .depth4])
    }

    func testAllocatorCreatesOnePagePerFullPageDemandWithoutSkips() throws {
        let candidates = try (0..<8).map { index in
            try makeCandidate(index: index,
                              source: Tile(x: index, y: 0, z: 10),
                              target: Tile(x: index, y: 0, z: 10),
                              screenDemandPx: 3000,
                              distanceToCamera: Float(index))
        }

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: candidates)

        XCTAssertEqual(plan.allocations.count, 8)
        XCTAssertEqual(plan.pageSummaries.count, 8)
        XCTAssertEqual(plan.skippedAllocationCount, 0)
        XCTAssertEqual(plan.downgradedAllocationCount, 0)
        XCTAssertEqual(Set(plan.allocations.map(\.atlasDepth)), [.depth0])
    }

    func testDebugSummaryCountsUpscaledFallbackSlot() throws {
        let fallback = try makeCandidate(index: 0,
                                         source: Tile(x: 0, y: 0, z: 3),
                                         target: Tile(x: 0, y: 0, z: 5),
                                         screenDemandPx: 128,
                                         distanceToCamera: 0)

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [fallback])

        let summary = TileAtlasDebugSummary(plan: plan)

        XCTAssertEqual(summary.slotCount(depth: .depth0), 1)
    }

    func testTileAtlasDebugSummaryIncludesPageAllocationLayout() throws {
        let fallback = try makeCandidate(index: 0,
                                         source: Tile(x: 4, y: 2, z: 3),
                                         target: Tile(x: 17, y: 10, z: 5),
                                         screenDemandPx: 1700,
                                         distanceToCamera: 0.1)
        let exact = try makeCandidate(index: 1,
                                      source: Tile(x: 18, y: 10, z: 5),
                                      target: Tile(x: 18, y: 10, z: 5),
                                      screenDemandPx: 260,
                                      distanceToCamera: 0.2)
        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [exact, fallback])

        let summary = TileAtlasDebugSummary(plan: plan)

        XCTAssertEqual(summary.pages.count, 1)
        XCTAssertEqual(summary.pages[0].pageIndex, 0)
        XCTAssertEqual(summary.pages[0].allocations.count, 2)
        XCTAssertEqual(summary.pages[0].allocations[0].sourceTile, Tile(x: 4, y: 2, z: 3))
        XCTAssertEqual(summary.pages[0].allocations[0].targetTile, Tile(x: 17, y: 10, z: 5))
        XCTAssertEqual(summary.pages[0].allocations[0].atlasDepth, .depth1)
        XCTAssertEqual(summary.pages[0].allocations[0].cellSizePx, 2048)
        XCTAssertTrue(summary.pages[0].allocations[0].isFallback)
        XCTAssertEqual(summary.pages[0].allocations[1].sourceTile, Tile(x: 18, y: 10, z: 5))
        XCTAssertEqual(summary.pages[0].allocations[1].targetTile, Tile(x: 18, y: 10, z: 5))
        XCTAssertEqual(summary.pages[0].allocations[1].atlasDepth, .depth1)
        XCTAssertEqual(summary.pages[0].allocations[1].cellSizePx, 2048)
        XCTAssertFalse(summary.pages[0].allocations[1].isFallback)
    }

    func testTileAtlasDebugSummaryKeepsAllocationLodKind() throws {
        let coarse = try makeCandidate(index: 0,
                                       source: Tile(x: 4, y: 2, z: 5),
                                       target: Tile(x: 4, y: 2, z: 5),
                                       screenDemandPx: 300,
                                       distanceToCamera: 0,
                                       lodKind: .coarseSubstitute)

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [coarse])

        let summary = TileAtlasDebugSummary(plan: plan)

        XCTAssertEqual(summary.pages[0].allocations[0].lodKind, .coarseSubstitute)
        XCTAssertTrue(summary.pages[0].allocations[0].isFallback)
    }

    func testTextureTreeRejectsParentSlotAfterChildSlotAllocated() {
        let tree = TileAtlasSlotTree()

        XCTAssertNotNil(tree.addNewValue(value: TextureValue(), depth: 1))
        XCTAssertNil(tree.addNewValue(value: TextureValue(), depth: 0))
    }

    func testAllocatorKeepsMixedDemandSetAtEachDesiredDepthWithoutOverlaps() throws {
        let large = try makeCandidate(index: 0,
                                      source: Tile(x: 0, y: 0, z: 3),
                                      target: Tile(x: 0, y: 0, z: 3),
                                      screenDemandPx: 1500,
                                      distanceToCamera: 0.0)
        let small = try (1...13).map { index in
            try makeCandidate(index: index,
                              source: Tile(x: index, y: 0, z: 5),
                              target: Tile(x: index, y: 0, z: 5),
                              screenDemandPx: 900,
                              distanceToCamera: Float(index))
        }

        let plan = TileAtlasPlacementPlanner(pageSizePx: 4096)
            .plan(candidates: [large] + small)

        assertNoOverlappingAllocations(plan.allocations)
        XCTAssertEqual(plan.allocations.count, 14)
        XCTAssertEqual(plan.allocations.first?.atlasDepth, .depth0)
        XCTAssertEqual(Array(plan.allocations.dropFirst()).map(\.atlasDepth),
                       [.depth1] + Array(repeating: .depth2, count: 12))
        XCTAssertEqual(plan.downgradedAllocationCount, 0)
        XCTAssertEqual(plan.skippedAllocationCount, 0)
    }

    func testMakeCandidateUsesTargetTileFootprintNotSourceTileZoom() throws {
        let source = Tile(x: 4, y: 2, z: 3)
        let target = Tile(x: 17, y: 10, z: 5)
        let metalTile = MetalTile(tile: source, tileBuffers: try makeTileBuffers())
        let placeTile = PlaceTile(metalTile: metalTile,
                                  placeIn: VisibleTile(tile: target),
                                  lodKind: .retainedReplacement)

        let candidate = TileAtlasPlacementPlanner.makeCandidateForTesting(
            placementIndex: 0,
            placeTile: placeTile,
            screenBoundsPx: CGRect(x: 100, y: 100, width: 1300, height: 800),
            pageSizePx: 4096
        )

        XCTAssertEqual(candidate.placeTile.metalTile.tile, source)
        XCTAssertEqual(candidate.placeTile.placeIn.tile, target)
        XCTAssertEqual(candidate.screenDemandPx, 1300, accuracy: 0.1)
        XCTAssertEqual(candidate.desiredDepth, .depth1)
        XCTAssertTrue(candidate.isFallback)
    }

    /// Demand обслуживает растянутую ось следа, но анизотропия капится 4×:
    /// полоса у горизонта получает малый слот, квадратный тайл - слот по
    /// стороне, ближний тайл во весь экран - полноразмерный слот.
    func testDemandCapsSlotAnisotropyOfDistortedFootprint() throws {
        let metalTile = MetalTile(tile: Tile(x: 9, y: 9, z: 5), tileBuffers: try makeTileBuffers())
        let placeTile = PlaceTile(metalTile: metalTile,
                                  placeIn: VisibleTile(tile: Tile(x: 9, y: 9, z: 5)),
                                  lodKind: .exact)

        let horizonStrip = TileAtlasPlacementPlanner.makeCandidateForTesting(
            placementIndex: 0,
            placeTile: placeTile,
            screenBoundsPx: CGRect(x: 0, y: 80, width: 1500, height: 60),
            pageSizePx: 4096
        )
        let squareTile = TileAtlasPlacementPlanner.makeCandidateForTesting(
            placementIndex: 1,
            placeTile: placeTile,
            screenBoundsPx: CGRect(x: 100, y: 100, width: 900, height: 900),
            pageSizePx: 4096
        )
        let nearFullScreenTile = TileAtlasPlacementPlanner.makeCandidateForTesting(
            placementIndex: 2,
            placeTile: placeTile,
            screenBoundsPx: CGRect(x: 0, y: 1000, width: 3360, height: 900),
            pageSizePx: 4096
        )

        XCTAssertEqual(horizonStrip.screenDemandPx, 240, accuracy: 0.1)
        XCTAssertEqual(horizonStrip.desiredDepth, .depth4)
        XCTAssertEqual(squareTile.screenDemandPx, 900, accuracy: 0.1)
        XCTAssertEqual(squareTile.desiredDepth, .depth2)
        XCTAssertEqual(nearFullScreenTile.screenDemandPx, 3360, accuracy: 0.1)
        XCTAssertEqual(nearFullScreenTile.desiredDepth, .depth0)
    }

    func testMakeCandidatesUsesTargetTileForFallbackFootprint() throws {
        let source = Tile(x: 4, y: 4, z: 3)
        let target = Tile(x: 16, y: 16, z: 5)
        let metalTile = MetalTile(tile: source, tileBuffers: try makeTileBuffers())
        let fallback = PlaceTile(metalTile: metalTile,
                                 placeIn: VisibleTile(tile: target),
                                 lodKind: .retainedReplacement)
        let exact = PlaceTile(metalTile: MetalTile(tile: target, tileBuffers: try makeTileBuffers()),
                              placeIn: VisibleTile(tile: target),
                              lodKind: .exact)
        let frameContext = makeGlobeFrameContext()
        let planner = TileAtlasPlacementPlanner(pageSizePx: 4096)

        let fallbackCandidate = try XCTUnwrap(planner.makeCandidates(placeTiles: [fallback],
                                                                     frameContext: frameContext).first)
        let exactCandidate = try XCTUnwrap(planner.makeCandidates(placeTiles: [exact],
                                                                  frameContext: frameContext).first)

        XCTAssertEqual(fallbackCandidate.placeTile.metalTile.tile, source)
        XCTAssertEqual(fallbackCandidate.placeTile.placeIn.tile, target)
        XCTAssertEqual(fallbackCandidate.screenDemandPx, exactCandidate.screenDemandPx, accuracy: 0.1)
        XCTAssertLessThanOrEqual(fallbackCandidate.screenDemandPx, 1024)
        XCTAssertEqual(fallbackCandidate.desiredDepth, exactCandidate.desiredDepth)
        XCTAssertTrue(fallbackCandidate.distanceToCamera.isFinite)
        XCTAssertLessThan(fallbackCandidate.distanceToCamera, Float.greatestFiniteMagnitude)
        XCTAssertTrue(fallbackCandidate.isFallback)
    }

    func testMakeCandidatesKeepsWholeWorldTileVisibleAtLowZoom() throws {
        let tile = Tile(x: 0, y: 0, z: 0)
        let metalTile = MetalTile(tile: tile, tileBuffers: try makeTileBuffers())
        let placeTile = PlaceTile(metalTile: metalTile,
                                  placeIn: VisibleTile(tile: tile),
                                  lodKind: .exact)
        let frameContext = try makeGlobeFrameContext(latitudeDegrees: 8.010,
                                                     longitudeDegrees: -84.442,
                                                     zoom: 0.86,
                                                     bearingDegrees: 15.0,
                                                     drawSize: CGSize(width: 3742, height: 2258))
        let planner = TileAtlasPlacementPlanner(pageSizePx: 4096)

        let candidates = planner.makeCandidates(placeTiles: [placeTile],
                                                frameContext: frameContext)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.placeTile.placeIn.tile, tile)
    }

    func testScreenFootprintIgnoresProjectedSamplesThatFailHorizonVisibility() {
        let footprint = TileAtlasPlacementPlanner.screenFootprintForTesting(
            projectedSamples: [
                (position: SIMD2<Float>(100, 100), depth: 0.1, passesHorizon: false),
                (position: SIMD2<Float>(400, 300), depth: 0.2, passesHorizon: false)
            ],
            viewport: SIMD2<Float>(1024, 768)
        )

        XCTAssertNil(footprint)
    }

    func testScreenFootprintBuildsBoundsFromOnlyHorizonVisibleSamples() throws {
        let footprint = try XCTUnwrap(TileAtlasPlacementPlanner.screenFootprintForTesting(
            projectedSamples: [
                (position: SIMD2<Float>(100, 100), depth: 0.1, passesHorizon: false),
                (position: SIMD2<Float>(400, 300), depth: 0.2, passesHorizon: true),
                (position: SIMD2<Float>(700, 500), depth: 0.3, passesHorizon: true)
            ],
            viewport: SIMD2<Float>(1024, 768)
        ))

        XCTAssertEqual(footprint.minX, 400, accuracy: 0.1)
        XCTAssertEqual(footprint.minY, 300, accuracy: 0.1)
        XCTAssertEqual(footprint.width, 300, accuracy: 0.1)
        XCTAssertEqual(footprint.height, 200, accuracy: 0.1)
    }

    private func makeCandidate(index: Int,
                               source: Tile,
                               target: Tile,
                               screenDemandPx: Float,
                               distanceToCamera: Float,
                               lodKind: TileLodKind? = nil) throws -> TileAtlasCandidate {
        let metalTile = MetalTile(tile: source, tileBuffers: try makeTileBuffers())
        let placeTile = PlaceTile(metalTile: metalTile,
                                  placeIn: VisibleTile(tile: target),
                                  lodKind: lodKind ?? (source == target ? .exact : .retainedReplacement))
        return TileAtlasCandidate(placementIndex: index,
                                   placeTile: placeTile,
                                   screenDemandPx: screenDemandPx,
                                   distanceToCamera: distanceToCamera,
                                   desiredDepth: TileAtlasSlotDepth.desired(forScreenDemandPx: screenDemandPx,
                                                                             pageSizePx: 4096))
    }

    private func stableAllocationLayout(_ plan: TileAtlasPlan) -> [AllocationLayout] {
        plan.allocations
            .map {
                AllocationLayout(target: $0.placeTile.placeIn.tile,
                                 source: $0.placeTile.metalTile.tile,
                                 pageIndex: $0.pageIndex,
                                 position: $0.placedPosition,
                                 atlasDepth: $0.atlasDepth)
            }
            .sorted {
                if $0.target.z != $1.target.z {
                    return $0.target.z < $1.target.z
                }
                if $0.target.x != $1.target.x {
                    return $0.target.x < $1.target.x
                }
                return $0.target.y < $1.target.y
            }
    }

    private struct AllocationLayout: Equatable {
        let target: Tile
        let source: Tile
        let pageIndex: Int
        let position: PlacedPos
        let atlasDepth: TileAtlasSlotDepth
    }

    private func makeTileBuffers() throws -> TileBuffers {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for MetalTile test fixture.")
        }
        let value: UInt32 = 0
        let buffer = device.makeBuffer(bytes: [value], length: MemoryLayout<UInt32>.stride)!
        let ground = TileBuffers.GeometryLayer(verticesBuffer: buffer,
                                               indicesBuffer: buffer,
                                               stylesBuffer: buffer,
                                               overviewStyleMaskBuffer: buffer,
                                               indicesCount: 0,
                                               verticesCount: 0)
        let extruded = TileBuffers.Extruded(verticesBuffer: buffer,
                                            indicesBuffer: buffer,
                                            stylesBuffer: buffer,
                                            indicesCount: 0,
                                            verticesCount: 0)
        let phases = RoadGeometryPhases(shadow: ground,
                                        casing: ground,
                                        fill: ground,
                                        detail: ground,
                                        overlay: ground)
        let roads = RoadStructureBuckets(tunnel: phases,
                                         ground: phases,
                                         bridge: phases)
        let emptyTextLabelSet = TileBuffers.TextLabelSet(placementInputs: [],
                                                         labelsByStyleRuns: [],
                                                         poiIconRuns: [])
        return TileBuffers(ground: ground,
                           roads: roads,
                           bridgeOverlay: ground,
                           extruded: extruded,
                           textLabels: TileBuffers.TextLabels(full: emptyTextLabelSet,
                                                               reduced: emptyTextLabelSet,
                                                               minimal: emptyTextLabelSet),
                           roadLabels: TileBuffers.RoadLabels(pathInputs: [],
                                                              pathRanges: [],
                                                              pathLabels: [],
                                                              labelStyle: nil,
                                                              localGlyphVerticesBuffer: nil,
                                                              localGlyphVertexCount: 0,
                                                              glyphBounds: [],
                                                              glyphBoundRanges: [],
                                                              sizes: [],
                                                              anchorRanges: [],
                                                              anchors: []))
    }

    private func makeGlobeFrameContext() -> FrameContext {
        let settings = ImmersiveMapSettings.default
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: SIMD2<Double>(0.5, 0.5),
                                                  zoom: 5.0,
                                                  bearing: 0,
                                                  pitch: 0)
        let diagnostics = FrameDiagnostics(frameIndex: 0, frameTime: 0)
        return FrameContext(frameIndex: 0,
                            time: 0,
                            deltaTime: 0,
                            drawSize: CGSize(width: 1024, height: 768),
                            viewport: SIMD2<Float>(1024, 768),
                            cameraMatrices: .identity,
                            cameraEye: SIMD3<Float>(0, 0, 1),
                            qualityTier: .low,
                            commandBuffer: nil,
                            drawable: nil,
                            services: FrameContextServices(diagnostics: diagnostics,
                                                           settings: settings,
                                                           now: Date(timeIntervalSince1970: 0)),
                            mapCameraState: cameraState,
                            resolvedPresentation: PresentationStateResolver.resolve(cameraState: cameraState,
                                                                                   settings: settings.presentation,
                                                                                   forcedRenderSurfaceMode: .spherical),
                            diagnostics: diagnostics)
    }

    private func makeGlobeFrameContext(latitudeDegrees: Double,
                                       longitudeDegrees: Double,
                                       zoom: Double,
                                       bearingDegrees: Double,
                                       drawSize: CGSize) throws -> FrameContext {
        let settings = ImmersiveMapSettings.default
        let center = ImmersiveMapProjection.worldMercator(latitude: latitudeDegrees * Double.pi / 180.0,
                                                          longitude: longitudeDegrees * Double.pi / 180.0)
        let cameraState = ImmersiveMapCameraState(centerWorldMercator: center,
                                                  zoom: zoom,
                                                  bearing: Float(bearingDegrees * Double.pi / 180.0),
                                                  pitch: 0)
        let resolver = FrameCameraStateResolver(settings: settings)
        resolver.setCameraState(cameraState)
        let diagnostics = FrameDiagnostics(frameIndex: 0, frameTime: 0)
        guard let cameraFrameState = resolver.makeFrameState(drawSize: drawSize,
                                                             diagnostics: diagnostics) else {
            throw XCTSkip("Camera frame state is required for globe atlas regression fixture.")
        }
        let resolvedPresentation = PresentationStateResolver.resolve(cameraState: cameraFrameState.mapCameraState,
                                                                     settings: settings.presentation,
                                                                     forcedRenderSurfaceMode: .spherical)
        return FrameContext(frameIndex: 0,
                            time: 0,
                            deltaTime: 0,
                            drawSize: drawSize,
                            viewport: SIMD2<Float>(Float(drawSize.width), Float(drawSize.height)),
                            cameraMatrices: cameraFrameState.cameraMatrices,
                            cameraEye: cameraFrameState.cameraEye,
                            qualityTier: cameraFrameState.qualityTier,
                            commandBuffer: nil,
                            drawable: nil,
                            services: FrameContextServices(diagnostics: diagnostics,
                                                           settings: settings,
                                                           now: Date(timeIntervalSince1970: 0)),
                            mapCameraState: cameraFrameState.mapCameraState,
                            resolvedPresentation: resolvedPresentation,
                            diagnostics: diagnostics)
    }

    private func assertNoOverlappingAllocations(_ allocations: [TileAtlasAllocation],
                                                file: StaticString = #filePath,
                                                line: UInt = #line) {
        for leftIndex in allocations.indices {
            for rightIndex in allocations.index(after: leftIndex)..<allocations.endIndex {
                let left = allocations[leftIndex]
                let right = allocations[rightIndex]
                guard left.pageIndex == right.pageIndex else {
                    continue
                }
                XCTAssertFalse(atlasRect(left).intersects(atlasRect(right)),
                               "Overlapping atlas allocations: \(left) and \(right)",
                               file: file,
                               line: line)
            }
        }
    }

    private func atlasRect(_ allocation: TileAtlasAllocation) -> AtlasRect {
        let commonDepth = Int(TileAtlasSlotDepth.depth4.rawValue)
        let depth = Int(allocation.atlasDepth.rawValue)
        let scale = 1 << (commonDepth - depth)
        let minX = Int(allocation.placedPosition.x) * scale
        let minY = Int(allocation.placedPosition.y) * scale
        return AtlasRect(minX: minX,
                         minY: minY,
                         maxX: minX + scale,
                         maxY: minY + scale)
    }
}

private struct AtlasRect {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    func intersects(_ other: AtlasRect) -> Bool {
        minX < other.maxX &&
            maxX > other.minX &&
            minY < other.maxY &&
            maxY > other.minY
    }
}
