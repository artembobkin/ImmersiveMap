// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The demand plan: every target, and for a target not resident yet at most
/// one stand-in ancestor that is already available locally. Nothing is
/// asked for blindly.
final class TileDemandSourcePlannerTests: XCTestCase {
    private let target = Tile(x: 38, y: 19, z: 6)
    private let parent = Tile(x: 19, y: 9, z: 5)
    private let grandparent = Tile(x: 9, y: 4, z: 4)

    private func plan(targets: [Tile],
                      backdropZoomLevel: Int? = 3,
                      resident: Set<Tile> = [],
                      available: Set<Tile> = []) -> TileDemandSourcePlan {
        TileDemandSourcePlanner.makePlan(targets: targets.map { VisibleTile(tile: $0) },
                                         backdropZoomLevel: backdropZoomLevel,
                                         isResident: { resident.contains($0) },
                                         isAvailableLocally: { resident.contains($0) || available.contains($0) })
    }

    func testResidentTargetDemandsOnlyItself() {
        let plan = plan(targets: [target], resident: [target], available: [parent, grandparent])
        XCTAssertEqual(plan.demandedSourceTiles, [target])
        XCTAssertTrue(plan.fallbackAncestorByTarget.isEmpty)
    }

    func testLoadingTargetDemandsItsAvailableParent() {
        let plan = plan(targets: [target], available: [parent, grandparent])
        XCTAssertEqual(plan.demandedSourceTiles, [target, parent])
        XCTAssertEqual(plan.fallbackAncestorByTarget[target], parent)
    }

    func testLoadingTargetFallsBackToTheGrandparentWhenOnlyItIsAvailable() {
        let plan = plan(targets: [target], available: [grandparent])
        XCTAssertEqual(plan.demandedSourceTiles, [target, grandparent])
    }

    func testNothingAvailableDemandsOnlyTheTarget() {
        let plan = plan(targets: [target])
        XCTAssertEqual(plan.demandedSourceTiles, [target])
        XCTAssertTrue(plan.fallbackAncestorByTarget.isEmpty)
    }

    func testTheFlatBackdropBoundsTheWalk() {
        let z5 = Tile(x: 19, y: 9, z: 5)
        let z3 = Tile(x: 4, y: 2, z: 3)
        let z2 = Tile(x: 2, y: 1, z: 2)
        XCTAssertEqual(plan(targets: [z5], backdropZoomLevel: 3, available: [z3, z2]).demandedSourceTiles, [z5],
                       "An ancestor at the backdrop's zoom or coarser is never worth demanding")
        XCTAssertEqual(plan(targets: [z5], backdropZoomLevel: 3, available: [grandparent]).demandedSourceTiles, [z5, grandparent],
                       "One level above the backdrop is")
    }

    func testTheGlobeWalksDownToTheWorldCover() {
        let z5 = Tile(x: 19, y: 9, z: 5)
        let z0 = Tile(x: 0, y: 0, z: 0)
        XCTAssertEqual(plan(targets: [z5], backdropZoomLevel: nil, available: [z0]).demandedSourceTiles, [z5, z0])
    }

    func testBackdropTargetsGetNoAncestors() {
        let z3 = Tile(x: 4, y: 2, z: 3)
        let z2 = Tile(x: 2, y: 1, z: 2)
        XCTAssertEqual(plan(targets: [z3], backdropZoomLevel: 3, available: [z2]).demandedSourceTiles, [z3])
    }

    func testSiblingsShareOneStandIn() {
        let sibling = Tile(x: 39, y: 19, z: 6)
        let plan = plan(targets: [target, sibling], available: [parent])
        XCTAssertEqual(plan.demandedSourceTiles, [target, parent, sibling])
        XCTAssertEqual(plan.fallbackAncestorByTarget[sibling], parent)
    }

    func testTheCameraOrderCarriesTheSameTiles() {
        let sibling = Tile(x: 39, y: 19, z: 6)
        let other = Tile(x: 40, y: 20, z: 6)
        let otherParent = Tile(x: 20, y: 10, z: 5)
        let plan = plan(targets: [target, sibling, other], available: [parent, otherParent])
        let ordered = plan.demandedSourceTiles(orderedBy: [other, sibling, target].map { VisibleTile(tile: $0) })
        XCTAssertEqual(Set(ordered), Set(plan.demandedSourceTiles))
        XCTAssertEqual(ordered.count, plan.demandedSourceTiles.count, "no duplicates")
        XCTAssertEqual(ordered.first, other, "The first prioritized target loads first")
        XCTAssertEqual(ordered[1], otherParent, "followed by its stand-in")
    }

    func testWrappedCopiesOfOneTileDeduplicate() {
        let plan = TileDemandSourcePlanner.makePlan(targets: [VisibleTile(tile: target, loop: 0),
                                                              VisibleTile(tile: target, loop: 1)],
                                                    backdropZoomLevel: 3,
                                                    isResident: { _ in false },
                                                    isAvailableLocally: { [parent].contains($0) })
        XCTAssertEqual(plan.demandedSourceTiles, [target, parent])
    }

    func testAvailabilityIsAskedOncePerAncestor() {
        let sibling = Tile(x: 39, y: 19, z: 6)
        var asked: [Tile] = []
        _ = TileDemandSourcePlanner.makePlan(targets: [target, sibling].map { VisibleTile(tile: $0) },
                                             backdropZoomLevel: 3,
                                             isResident: { _ in false },
                                             isAvailableLocally: { asked.append($0); return false })
        XCTAssertEqual(asked, [parent, grandparent], "Both siblings share the parent and the grandparent, each asked once")
    }
}
