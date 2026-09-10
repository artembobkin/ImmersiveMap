// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The building coverage: a partition of the near field over the resident
/// tiles. Every needed slot of the quadtree under a z14 cell draws the
/// finest resident tile that covers it: a resident tile draws itself where
/// nothing finer the view needs is resident under it, and clipped to the
/// slots of the needed descendants it has none for. Coarser than z14 never
/// draws buildings, and a missing tile borrows no coarser parent than the
/// resident ones above it.
final class BuildingCoveragePlannerTests: XCTestCase {
    private let cell = Tile(x: 9908, y: 5140, z: 14)
    private var children: [Tile] {
        [Tile(x: 19816, y: 10280, z: 15), Tile(x: 19817, y: 10280, z: 15),
         Tile(x: 19816, y: 10281, z: 15), Tile(x: 19817, y: 10281, z: 15)]
    }
    private var eye: SIMD2<Double> {
        SIMD2<Double>(Double(cell.x) + 0.5, Double(cell.y) + 0.5)
    }

    private func grandchildren(of child: Tile) -> [Tile] {
        var tiles: [Tile] = []
        for dy in 0 ... 1 {
            for dx in 0 ... 1 {
                tiles.append(Tile(x: child.x * 2 + dx, y: child.y * 2 + dy, z: 16))
            }
        }
        return tiles
    }

    private func resident(_ tiles: [Tile]) throws -> [Tile: MetalTile] {
        var resident: [Tile: MetalTile] = [:]
        for tile in tiles {
            resident[tile] = MetalTile(tile: tile, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
        }
        return resident
    }

    /// The whole cell in view at `zoom`: every descendant of the cell at
    /// that zoom is visible.
    private func wholeCellVisible(at zoom: Int, loop: Int8 = 0) -> [VisibleTile] {
        let span = 1 << (zoom - cell.z)
        var tiles: [VisibleTile] = []
        for dx in 0 ..< span {
            for dy in 0 ..< span {
                tiles.append(VisibleTile(x: cell.x * span + dx, y: cell.y * span + dy, z: zoom, loop: loop))
            }
        }
        return tiles
    }

    private func plan(resident: [Tile: MetalTile], visible: [VisibleTile]? = nil, eye: SIMD2<Double>? = nil) -> PlaceTilesContext {
        BuildingCoveragePlanner.plan(resident: resident,
                                     visibleTiles: visible ?? wholeCellVisible(at: 16),
                                     eyeGroundCell: eye ?? self.eye)
    }

    /// (source, slot) pairs of the placements.
    private func pairs(_ context: PlaceTilesContext) -> Set<Pair> {
        Set(context.tilePlacements.map { Pair(source: $0.metalTile.tile, slot: $0.placeIn.tile) })
    }

    private struct Pair: Hashable {
        let source: Tile
        let slot: Tile
    }

    private func own(_ tiles: [Tile]) -> Set<Pair> {
        Set(tiles.map { Pair(source: $0, slot: $0) })
    }

    func testTheCellFillsTheSlotsOfTheChildrenThatAreMissing() throws {
        let resident = try resident([cell, children[0], children[1]])
        let context = plan(resident: resident)
        XCTAssertEqual(pairs(context),
                       own([children[0], children[1]])
                           .union([Pair(source: cell, slot: children[2]), Pair(source: cell, slot: children[3])]),
                       "Two children draw themselves; the cell draws clipped to the two missing quadrants")
        for placement in context.tilePlacements {
            let clipped = placement.metalTile.tile != placement.placeIn.tile
            XCTAssertEqual(placement.lodKind, clipped ? .coarseSubstitute : .exact,
                           "A clipped placement is a coarse substitute, one in its own slot is exact")
        }
    }

    func testTheCellHandsOverWhollyWhenEveryNeededChildIsResident() throws {
        let resident = try resident([cell] + children)
        let context = plan(resident: resident)
        XCTAssertEqual(pairs(context), own(children))
        XCTAssertFalse(context.tilePlacements.contains { $0.metalTile.tile == cell }, "The parent is not drawn under complete children")
    }

    func testTheCellDrawsWholeWhenNothingFinerIsResident() throws {
        let context = plan(resident: try resident([cell]))
        XCTAssertEqual(pairs(context), own([cell]), "One draw at full extent, not four clipped ones")
    }

    /// A child no visible tile lies in is not needed: with one child out of
    /// the view, the three in it draw and the cell draws nothing.
    func testAChildOutsideTheViewIsNotNeeded() throws {
        let hidden = children[3]
        let visible = wholeCellVisible(at: 16).filter { tile in
            tile.tile.findParentTile(atZoom: 15) != hidden
        }
        let resident = try resident([cell] + children.dropLast())
        let context = plan(resident: resident, visible: visible)
        XCTAssertEqual(pairs(context), own(Array(children.dropLast())), "The three children in view draw; the fourth is off screen")
    }

    /// The same view with the fourth child in it: the cell fills that one
    /// slot, and the three resident children keep drawing themselves.
    func testAChildInsideTheViewIsFilledByTheCell() throws {
        let resident = try resident([cell] + children.dropLast())
        XCTAssertEqual(pairs(plan(resident: resident)),
                       own(Array(children.dropLast())).union([Pair(source: cell, slot: children[3])]))
    }

    /// The nearest tile keeps its own buildings whatever the view needs
    /// elsewhere in the cell: the theatre case. The near z15 child and two
    /// of its z16 children are resident, the far children are not, and
    /// turning the view (a different set of needed far slots) changes only
    /// what the cell fills, never what the near tiles draw.
    func testResidentNearTilesDrawThemselvesWhateverTheFarSlotsNeed() throws {
        let near = children[0]
        let nearGrandchildren = grandchildren(of: near)
        let resident = try resident([cell, near, nearGrandchildren[0], nearGrandchildren[1]])
        for hiddenChild in [children[1], children[2], children[3]] {
            let visible = wholeCellVisible(at: 16).filter { $0.tile.findParentTile(atZoom: 15) != hiddenChild }
            let context = plan(resident: resident, visible: visible)
            let ownPlacements = pairs(context).filter { $0.source == $0.slot }
            XCTAssertEqual(ownPlacements, own([nearGrandchildren[0], nearGrandchildren[1]]),
                           "The two resident z16 tiles draw themselves with \\(hiddenChild) out of view")
            XCTAssertTrue(pairs(context).contains(Pair(source: near, slot: nearGrandchildren[2])),
                          "The near child fills its missing z16 slots")
            XCTAssertTrue(pairs(context).contains(Pair(source: near, slot: nearGrandchildren[3])))
            let cellFills = pairs(context).filter { $0.source == cell }.map(\.slot)
            XCTAssertEqual(Set(cellFills), Set(children.dropFirst().filter { $0 != hiddenChild }),
                           "The cell fills exactly the far quadrants in view")
        }
    }

    /// A tile that is resident but not placed by the ground (the retention)
    /// still counts: the planner reads residency, not the placement.
    func testResidencyIsWhatCounts() throws {
        let resident = try resident(children)
        XCTAssertEqual(pairs(plan(resident: resident)), own(children))
    }

    func testAGrandchildLevelHandsOverTheSameWay() throws {
        let last = children[3]
        let placed = plan(resident: try resident([cell] + children.dropLast() + grandchildren(of: last)))
        XCTAssertEqual(pairs(placed), own(Array(children.dropLast()) + grandchildren(of: last)))
    }

    func testAChildFillsTheSlotsOfItsMissingGrandchildren() throws {
        let last = children[3]
        let one = grandchildren(of: last)[0]
        let placed = plan(resident: try resident([cell] + children + [one]))
        var expected = own(Array(children.dropLast()) + [one])
        for missing in grandchildren(of: last).dropFirst() {
            expected.insert(Pair(source: last, slot: missing))
        }
        XCTAssertEqual(pairs(placed), expected, "One z16 grandchild draws itself; its parent fills the other three slots")
    }

    func testAMissingCellBorrowsNoParentButLendsItsResidentChildren() throws {
        let parent = Tile(x: 4954, y: 2570, z: 13)
        let placed = plan(resident: try resident([parent, children[0], children[2]]))
        XCTAssertEqual(pairs(placed), own([children[0], children[2]]),
                       "z13 is below the grid and the cell is not resident: the two resident children draw, nothing over them")
    }

    func testACompleteGrandchildLevelHandsOverWithoutParentOrChildren() throws {
        let all = children.flatMap { grandchildren(of: $0) }
        XCTAssertEqual(pairs(plan(resident: try resident(all))), own(all))
    }

    /// The cell fills the z16 slots a missing child has no resident
    /// grandchildren for, down at the grandchildren's level, so the
    /// resident grandchildren keep drawing themselves.
    func testTheCellFillsAroundTheResidentGrandchildrenOfAMissingChild() throws {
        let last = children[3]
        let present = Array(grandchildren(of: last).prefix(2))
        let placed = plan(resident: try resident([cell] + children.dropLast() + present))
        var expected = own(Array(children.dropLast()) + present)
        for missing in grandchildren(of: last).dropFirst(2) {
            expected.insert(Pair(source: cell, slot: missing))
        }
        XCTAssertEqual(pairs(placed), expected)
    }

    /// A missing child with resident grandchildren under a missing cell:
    /// the grandchildren draw and the rest stays empty.
    func testAMissingCellLeavesTheGapsOfAMissingChildEmpty() throws {
        let last = children[3]
        let present = Array(grandchildren(of: last).prefix(2))
        let placed = plan(resident: try resident(Array(children.dropLast()) + present))
        XCTAssertEqual(pairs(placed), own(Array(children.dropLast()) + present))
    }

    /// A zoom-out: the view is at z15, the z15 tiles have not arrived, and
    /// the z16 tiles the camera was just looking at are resident. They draw
    /// their buildings at their own extents until their parent lands, as
    /// the ground under them does.
    func testAMissingTargetHandsItsSlotToItsResidentFinerTiles() throws {
        let finer = grandchildren(of: children[0]) + grandchildren(of: children[3])
        let placed = plan(resident: try resident(finer), visible: wholeCellVisible(at: 15))
        XCTAssertEqual(pairs(placed), own(finer), "each finer tile draws whole, in its own slot")
    }

    func testAResidentTargetOutranksItsFinerTiles() throws {
        let finer = grandchildren(of: children[0])
        let placed = plan(resident: try resident([children[0]] + finer), visible: wholeCellVisible(at: 15))
        XCTAssertEqual(pairs(placed), own([children[0]]), "the target itself draws, the finer tiles under it stay unused")
    }

    func testAResidentCellFillsTheQuadrantsTheFinerTilesLeave() throws {
        // The cell is resident, one target is missing and only half of it is
        // covered by finer tiles: those draw, the cell is clipped into the
        // slots of the other three targets and into the two quadrants of
        // the missing target that no finer tile covers.
        let all = grandchildren(of: children[0])
        let finer = Array(all.prefix(2))
        let placed = plan(resident: try resident([cell] + finer), visible: wholeCellVisible(at: 15))
        var expected = own(finer)
        for child in children.dropFirst() {
            expected.insert(Pair(source: cell, slot: child))
        }
        for quadrant in all.dropFirst(2) {
            expected.insert(Pair(source: cell, slot: quadrant))
        }
        XCTAssertEqual(pairs(placed), expected)
    }

    func testTilesCoarserThanTheGridNeverDrawBuildings() throws {
        let placed = plan(resident: try resident([Tile(x: 4954, y: 2570, z: 13), Tile(x: 2477, y: 1285, z: 12)]))
        XCTAssertTrue(placed.tilePlacements.isEmpty)
    }

    func testCellsBeyondTheFieldRadiusAreSkipped() throws {
        let far = Tile(x: cell.x + 5, y: cell.y, z: 14)
        var visible = wholeCellVisible(at: 16)
        for dx in 0 ..< 4 {
            for dy in 0 ..< 4 {
                visible.append(VisibleTile(x: far.x * 4 + dx, y: far.y * 4 + dy, z: 16))
            }
        }
        let placed = plan(resident: try resident([cell, far]), visible: visible)
        XCTAssertEqual(pairs(placed), own([cell]))
    }

    func testWrappedCopiesStayApart() throws {
        // The same cell visible in two world copies: each copy draws it in
        // its own loop, and only the copy near the eye is in the field.
        let visible = wholeCellVisible(at: 16, loop: 0) + wholeCellVisible(at: 16, loop: 1)
        let eyeInLoopOne = eye + SIMD2<Double>(Double(1 << 14), 0)
        let context = BuildingCoveragePlanner.plan(resident: try resident([cell]), visibleTiles: visible, eyeGroundCell: eyeInLoopOne)
        XCTAssertEqual(context.tilePlacements.map(\.placeIn.loop), [1])
    }

    func testChildrenInAnotherWorldCopyDoNotCompleteTheCell() throws {
        // Loop 0 sees the cell; its children are visible only in loop 1. In
        // loop 0 nothing below the cell is needed by loop 1's view, so the
        // cell resolves in loop 0 from what loop 0 needs.
        let visible = wholeCellVisible(at: 16, loop: 0)
        let context = BuildingCoveragePlanner.plan(resident: try resident([cell] + children), visibleTiles: visible, eyeGroundCell: eye)
        XCTAssertTrue(context.tilePlacements.allSatisfy { $0.placeIn.loop == 0 })
        XCTAssertEqual(pairs(context), own(children), "loop 0 needs all four children and has them")
    }

    /// Zoomed out past the grid, the retention still holds the tiles of
    /// the closer view; none of them draws.
    func testAFrameCoarserThanTheGridDrawsNoBuildings() throws {
        let resident = try resident([cell] + children)
        let coarse = [VisibleTile(x: cell.x / 2, y: cell.y / 2, z: 13)]
        XCTAssertTrue(plan(resident: resident, visible: coarse).tilePlacements.isEmpty)
        let atTheGrid = [VisibleTile(tile: cell, loop: 0)]
        XCTAssertEqual(pairs(plan(resident: resident, visible: atTheGrid)), own([cell]),
                       "At the grid's own zoom the cell draws itself")
    }

    func testTheGlobeHasNoBuildingCoverage() throws {
        let context = BuildingCoveragePlanner.plan(resident: try resident([cell]), visibleTiles: wholeCellVisible(at: 16), eyeGroundCell: nil)
        XCTAssertTrue(context.tilePlacements.isEmpty)
    }

    func testTheOutputOrderIsDeterministic() throws {
        let resident = try resident([cell] + children)
        let placed = plan(resident: resident).tilePlacements.map(\.placeIn.tile)
        XCTAssertEqual(placed, children.sorted { ($0.x, $0.y) < ($1.x, $1.y) })
    }

    func testNoTwoPlacementsShareASlotAndNoSlotLiesUnderAnother() throws {
        let last = children[3]
        let present = Array(grandchildren(of: last).prefix(2))
        let context = plan(resident: try resident([cell] + children.dropLast() + present))
        let slots = context.tilePlacements.map(\.placeIn.tile)
        XCTAssertEqual(Set(slots).count, slots.count)
        for a in slots {
            for b in slots where a != b {
                XCTAssertFalse(a.covers(b), "\\(a) and \\(b) overlap")
            }
        }
    }
}
