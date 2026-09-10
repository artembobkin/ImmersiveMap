// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import MetalKit
import XCTest

/// The placement as a function of the targets and the resident tiles: a
/// resident target draws itself, a missing one draws its resident
/// descendants and, in the holes they leave, its finest resident ancestor
/// above the backdrop, else nothing. Nothing comes from a previous frame.
final class TilePlacementPlannerTests: XCTestCase {
    private let parent = Tile(x: 17, y: 11, z: 5)
    private var children: [Tile] {
        [Tile(x: 34, y: 22, z: 6), Tile(x: 35, y: 22, z: 6), Tile(x: 34, y: 23, z: 6), Tile(x: 35, y: 23, z: 6)]
    }
    private let grandparent = Tile(x: 8, y: 5, z: 4)

    private func resident(_ tiles: [Tile]) throws -> [Tile: MetalTile] {
        var resident: [Tile: MetalTile] = [:]
        for tile in tiles {
            resident[tile] = MetalTile(tile: tile, tileBuffers: try makeTileBuffers())
        }
        return resident
    }

    private func placements(targets: [Tile], resident: [Tile: MetalTile], zoom: Int, backdropZoomLevel: Int? = nil) -> [PlaceTile] {
        TilePlacementPlanner.buildPlacements(targets: targets.map { VisibleTile(tile: $0) },
                                             resident: resident,
                                             zoom: zoom,
                                             backdropZoomLevel: backdropZoomLevel).tilePlacements
    }

    func testAResidentTargetDrawsItself() throws {
        let resident = try resident([parent, grandparent])
        let placed = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first?.metalTile.tile, parent)
        XCTAssertEqual(placed.first?.placeIn.tile, parent)
        XCTAssertEqual(placed.first?.lodKind, .exact)
    }

    func testACoarserTargetIsMarkedAsASubstitute() throws {
        let resident = try resident([parent])
        let placed = placements(targets: [parent], resident: resident, zoom: 7)
        XCTAssertEqual(placed.first?.lodKind, .coarseSubstitute)
    }

    func testAMissingTargetDrawsItsFinestResidentAncestor() throws {
        let resident = try resident([grandparent, Tile(x: 4, y: 2, z: 3)])
        let placed = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first?.metalTile.tile, grandparent, "the finest ancestor, not the coarser one")
        XCTAssertEqual(placed.first?.placeIn.tile, parent, "placed in the target's slot")
        XCTAssertEqual(placed.first?.lodKind, .coarseSubstitute)
    }

    func testAnAncestorAtTheBackdropZoomIsNotASubstitute() throws {
        let resident = try resident([Tile(x: 4, y: 2, z: 3), Tile(x: 2, y: 1, z: 2)])
        let placed = placements(targets: [parent], resident: resident, zoom: 5, backdropZoomLevel: 3)
        XCTAssertTrue(placed.isEmpty, "z3 and coarser carry nothing the backdrop does not; the target is left to it")
        let withoutBackdrop = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(withoutBackdrop.first?.metalTile.tile, Tile(x: 4, y: 2, z: 3), "without a backdrop the z3 ancestor stands in")
    }

    func testCompleteResidentChildrenStandInForAMissingTarget() throws {
        let resident = try resident(children + [grandparent])
        let placed = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(Set(placed.map(\.metalTile.tile)), Set(children), "the four children cover the target whole")
        XCTAssertTrue(placed.allSatisfy { $0.placeIn.tile == $0.metalTile.tile && $0.lodKind == .retainedReplacement },
                      "each drawn at its own extent")
    }

    func testPartialChildrenStayAndTheAncestorFillsTheHoles() throws {
        let resident = try resident([children[0], grandparent])
        let placed = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(Set(placed.map(\.metalTile.tile)), [children[0], grandparent],
                       "the detailed child the camera saw stays, the coarse ancestor paints the rest")
        let child = placed.first { $0.metalTile.tile == children[0] }
        let ancestor = placed.first { $0.metalTile.tile == grandparent }
        XCTAssertEqual(child?.lodKind, .retainedReplacement)
        XCTAssertEqual(child?.placeIn.tile, children[0], "the child is drawn at its own extent")
        XCTAssertEqual(ancestor?.lodKind, .coarseSubstitute)
        XCTAssertEqual(ancestor?.placeIn.tile, parent, "the ancestor is placed for the whole target")
    }

    func testCompleteChildrenNeedNoAncestor() throws {
        let resident = try resident(children + [grandparent])
        let placed = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertFalse(placed.contains { $0.metalTile.tile == grandparent }, "no hole, nothing to fill")
    }

    func testPartialChildrenStandInWhenNoAncestorIsResident() throws {
        let resident = try resident([children[0], children[3]])
        let placed = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(Set(placed.map(\.metalTile.tile)), [children[0], children[3]], "better than an empty region")
    }

    func testNestedGrandchildrenCompleteAChild() throws {
        let missingChild = children[3]
        var grandchildren: [Tile] = []
        for dx in 0 ... 1 {
            for dy in 0 ... 1 {
                grandchildren.append(Tile(x: missingChild.x * 2 + dx, y: missingChild.y * 2 + dy, z: 7))
            }
        }
        let resident = try resident(Array(children.dropLast()) + grandchildren)
        let placed = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(Set(placed.map(\.metalTile.tile)), Set(children.dropLast() + grandchildren))
    }

    func testDescendantsStandInAtAnyDepth() throws {
        // A single tile eleven levels down, the block the camera was looking
        // at before a long zoom-out: it is placed at its own extent, and the
        // resident ancestor fills the rest.
        let deep = Tile(x: parent.x << 11, y: parent.y << 11, z: 16)
        let placed = placements(targets: [parent], resident: try resident([deep, grandparent]), zoom: 5)
        XCTAssertEqual(Set(placed.map(\.metalTile.tile)), [deep, grandparent])
        XCTAssertEqual(placed.first { $0.metalTile.tile == deep }?.placeIn.tile, deep)
    }

    func testNothingResidentPlacesNothing() throws {
        let placed = placements(targets: [parent], resident: [:], zoom: 5)
        XCTAssertTrue(placed.isEmpty)
    }

    /// Targets may overlap on the flat map: a missing parent and its missing
    /// child both find the resident grandchild below them, and it comes out
    /// once. (Emitting it per target, with the previous frame as the source,
    /// once doubled the list every frame until a frame took seconds.)
    func testAStandInInsideTwoOverlappingTargetsIsPlacedOnce() throws {
        let child = children[0]
        let grandchild = Tile(x: child.x * 2, y: child.y * 2, z: 7)
        let resident = try resident([grandchild])
        let placed = placements(targets: [child, parent], resident: resident, zoom: 7)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first?.metalTile.tile, grandchild)
    }

    func testAWrappedTargetKeepsItsLoopInEveryStandIn() throws {
        let resident = try resident([grandparent] + children)
        let wrapped = VisibleTile(tile: parent, loop: 1)
        let placed = TilePlacementPlanner.buildPlacements(targets: [wrapped], resident: resident, zoom: 5).tilePlacements
        XCTAssertEqual(Set(placed.map(\.metalTile.tile)), Set(children), "complete children win")
        XCTAssertTrue(placed.allSatisfy { $0.placeIn.loop == 1 }, "drawn in the target's world copy")

        let ancestorOnly = try self.resident([grandparent])
        let ancestor = TilePlacementPlanner.buildPlacements(targets: [wrapped], resident: ancestorOnly, zoom: 5).tilePlacements
        XCTAssertEqual(ancestor.first?.placeIn, wrapped)
        XCTAssertEqual(ancestor.first?.lodKind, .coarseSubstitute)
    }

    func testAResidentTargetAlsoStandsInForItsMissingChildren() throws {
        // Overlapping flat targets: the parent is a target of its own and
        // the stand-in of two loading children, so it is placed three
        // times, once per slot, with one source.
        let resident = try resident([parent])
        let placed = placements(targets: [parent, children[0], children[1]], resident: resident, zoom: 6)
        XCTAssertEqual(placed.count, 3)
        XCTAssertTrue(placed.allSatisfy { $0.metalTile.tile == parent })
        XCTAssertEqual(Set(placed.map(\.placeIn.tile)), [parent, children[0], children[1]])
        XCTAssertEqual(placed.first { $0.placeIn.tile == parent }?.lodKind, .coarseSubstitute, "a resident target coarser than the zoom")
    }

    func testTheBackdropContextSearchesNoDescendants() throws {
        let backdrop = Tile(x: 4, y: 2, z: 3)
        let resident = try resident([grandparent])
        let placed = TilePlacementPlanner.buildPlacements(targets: [VisibleTile(tile: backdrop)],
                                                          resident: resident,
                                                          zoom: 5,
                                                          descendantSearchDepth: 0).tilePlacements
        XCTAssertTrue(placed.isEmpty, "A z4 child of a missing backdrop slot belongs to the main coverage, not the backdrop")
    }

    func testTheOutputDoesNotDependOnAnyPreviousFrame() throws {
        let resident = try resident([grandparent])
        let first = placements(targets: [parent], resident: resident, zoom: 5)
        let again = placements(targets: [parent], resident: resident, zoom: 5)
        XCTAssertEqual(first, again)
        XCTAssertEqual(placements(targets: [parent], resident: [:], zoom: 5), [],
                       "once the ancestor is gone from residency it is gone from the placement, whatever was placed before")
    }

    private func makeTileBuffers() throws -> TileBuffers {
        try TileBuffersFixtures.makeEmptyTileBuffers()
    }

    private func emptyTextLabelSet() -> TileBuffers.TextLabelSet {
        TileBuffers.TextLabelSet(placementInputs: [],
                                 labelsByStyleRuns: [],
                                 poiIconRuns: [])
    }
}
