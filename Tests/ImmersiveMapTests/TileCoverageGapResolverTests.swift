// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileCoverageGapResolverTests: XCTestCase {
    // MARK: - paintedRegion

    func testPaintedRegionOfAnExactPlacementIsTheSlot() {
        let tile = Tile(x: 3, y: 5, z: 4)
        XCTAssertEqual(TileCoverageGapResolver.paintedRegion(placeIn: tile, source: tile), tile)
    }

    func testPaintedRegionOfAParentFallbackIsTheSlot() {
        let slot = Tile(x: 3, y: 5, z: 4)
        let parentSource = Tile(x: 0, y: 1, z: 2)
        XCTAssertEqual(TileCoverageGapResolver.paintedRegion(placeIn: slot, source: parentSource), slot)
    }

    func testPaintedRegionOfRetainedFinerContentIsTheSource() {
        let slot = Tile(x: 1, y: 1, z: 1)
        let finerSource = Tile(x: 2, y: 3, z: 2)
        XCTAssertEqual(TileCoverageGapResolver.paintedRegion(placeIn: slot, source: finerSource), finerSource)
    }

    func testPaintedRegionOfDisjointSlotAndSourceIsNothing() {
        let slot = Tile(x: 0, y: 0, z: 2)
        let elsewhere = Tile(x: 3, y: 3, z: 2)
        XCTAssertNil(TileCoverageGapResolver.paintedRegion(placeIn: slot, source: elsewhere))
    }

    // MARK: - uncoveredSlots

    func testTargetWithNoPaintIsUncoveredWhole() {
        let target = Tile(x: 1, y: 2, z: 3)
        XCTAssertEqual(TileCoverageGapResolver.uncoveredSlots(target: target, paintedRegions: []),
                       [target])
    }

    func testTargetPaintedExactlyHasNoGaps() {
        let target = Tile(x: 1, y: 2, z: 3)
        XCTAssertEqual(TileCoverageGapResolver.uncoveredSlots(target: target, paintedRegions: [target]),
                       [])
    }

    func testTargetUnderAPaintedAncestorHasNoGaps() {
        let target = Tile(x: 5, y: 6, z: 4)
        let ancestor = Tile(x: 1, y: 1, z: 2)
        XCTAssertEqual(TileCoverageGapResolver.uncoveredSlots(target: target, paintedRegions: [ancestor]),
                       [])
    }

    func testDisjointPaintIsIgnored() {
        let target = Tile(x: 0, y: 0, z: 2)
        let elsewhere = Tile(x: 3, y: 3, z: 2)
        XCTAssertEqual(TileCoverageGapResolver.uncoveredSlots(target: target, paintedRegions: [elsewhere]),
                       [target])
    }

    func testOnePaintedChildLeavesTheThreeSiblings() {
        let target = Tile(x: 1, y: 1, z: 1)
        let paintedChild = Tile(x: 2, y: 2, z: 2)

        let gaps = TileCoverageGapResolver.uncoveredSlots(target: target, paintedRegions: [paintedChild])

        XCTAssertEqual(Set(gaps), [Tile(x: 3, y: 2, z: 2),
                                   Tile(x: 2, y: 3, z: 2),
                                   Tile(x: 3, y: 3, z: 2)])
    }

    func testAPaintedGrandchildLeavesSiblingsOnBothLevels() {
        let target = Tile(x: 0, y: 0, z: 1)
        let paintedGrandchild = Tile(x: 0, y: 0, z: 3)

        let gaps = TileCoverageGapResolver.uncoveredSlots(target: target, paintedRegions: [paintedGrandchild])

        // The child holding the grandchild splits into its three unpainted
        // quarters; the other three children stay whole.
        XCTAssertEqual(Set(gaps), [Tile(x: 1, y: 0, z: 2),
                                   Tile(x: 0, y: 1, z: 2),
                                   Tile(x: 1, y: 1, z: 2),
                                   Tile(x: 1, y: 0, z: 3),
                                   Tile(x: 0, y: 1, z: 3),
                                   Tile(x: 1, y: 1, z: 3)])
    }

    func testFourPaintedChildrenCoverTheTarget() {
        let target = Tile(x: 1, y: 0, z: 1)
        let children = [Tile(x: 2, y: 0, z: 2),
                        Tile(x: 3, y: 0, z: 2),
                        Tile(x: 2, y: 1, z: 2),
                        Tile(x: 3, y: 1, z: 2)]

        XCTAssertEqual(TileCoverageGapResolver.uncoveredSlots(target: target, paintedRegions: children),
                       [])
    }
}
