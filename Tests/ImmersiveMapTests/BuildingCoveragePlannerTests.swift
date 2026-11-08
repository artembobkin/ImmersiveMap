// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The building coverage: the tiles the ground shows, from the buildings'
/// zoom on, draw their buildings in their own squares, however far from
/// the camera the ground places them. Where a coarser one stands in over
/// ground some of its children already show, the children draw and the
/// coarser one draws the quarters they leave, when it keeps its buildings
/// by quarters, and draws whole while they wait when it does not. Nothing
/// coarser than the buildings' zoom draws.
final class BuildingCoveragePlannerTests: XCTestCase {
    private let cell = Tile(x: 9908, y: 5140, z: 14)
    private var children: [Tile] {
        [Tile(x: 19816, y: 10280, z: 15), Tile(x: 19817, y: 10280, z: 15),
         Tile(x: 19816, y: 10281, z: 15), Tile(x: 19817, y: 10281, z: 15)]
    }
    /// The tiles in `quartered` keep their buildings by quarters, as a
    /// tile coarser than the tileset's deepest zoom does.
    private func resident(_ tiles: [Tile], quartered: Set<Tile> = []) throws -> [Tile: MetalTile] {
        var resident: [Tile: MetalTile] = [:]
        for tile in tiles {
            var extruded = TileBuffers.Extruded(vertices: nil, indices: nil, styles: nil, indexType: .uint16)
            if quartered.contains(tile) {
                extruded.quarterIndexStarts = [0, 0, 0, 0, 0]
            }
            resident[tile] = MetalTile(tile: tile, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers(extruded: extruded))
        }
        return resident
    }

    private func visible(_ tiles: [Tile], worldWrap: Int8 = 0) -> [VisibleTile] {
        tiles.map { VisibleTile(tile: $0, worldWrap: worldWrap) }
    }

    /// The buildings over the ground the planner shows for `visible`.
    private func plan(resident: [Tile: MetalTile],
                      visible: [VisibleTile],
                      minimumZoom: Int = 15) -> PlaceTilesContext {
        let ground = TilePlacementPlanner.buildPlacements(targets: visible,
                                                          resident: resident,
                                                          zoom: visible.map(\.z).max() ?? 0)
        return BuildingCoveragePlanner.plan(groundPlacements: ground.tilePlacements,
                                            onFlatMap: true,
                                            minimumZoom: minimumZoom)
    }

    private func slots(_ context: PlaceTilesContext) -> [Tile] {
        context.tilePlacements.map(\.placeIn.tile)
    }

    func testTheResidentTargetsDrawInTheirOwnPlaces() throws {
        let context = plan(resident: try resident(children), visible: visible(children))
        XCTAssertEqual(Set(slots(context)), Set(children))
        XCTAssertTrue(context.tilePlacements.allSatisfy(\.inOwnSlot))
    }

    private func quarters(of tile: Tile, in context: PlaceTilesContext) -> UInt8? {
        context.tilePlacements.first { $0.placeIn.tile == tile }?.quarters
    }

    /// The cell keeps its buildings by quarters and stands in for its two
    /// southern children: the two northern ones that are in draw theirs,
    /// whole, and the cell draws its southern quarters alone, so every
    /// building draws once and none of the ground is left without.
    func testTheFinerTilesDrawAndTheCoarserTileDrawsTheQuartersTheyLeave() throws {
        let context = plan(resident: try resident([cell] + children.prefix(2), quartered: [cell]),
                           visible: visible(children),
                           minimumZoom: 14)
        XCTAssertEqual(Set(slots(context)), Set([cell] + children.prefix(2)))
        XCTAssertEqual(quarters(of: cell, in: context), 0b1100, "The south-west and the south-east")
        for child in children.prefix(2) {
            XCTAssertEqual(quarters(of: child, in: context), TileQuarters.all, "Whole")
        }
        XCTAssertTrue(context.tilePlacements.allSatisfy(\.inOwnSlot), "In its own square")
    }

    /// With every child in, the cell draws none of its quarters and is
    /// left out.
    func testACoarserTileWhoseChildrenAreAllInDrawsNothing() throws {
        let ground = TilePlacementPlanner.buildPlacements(targets: visible(children),
                                                          resident: try resident(children),
                                                          zoom: 15).tilePlacements
        let cellPlacement = PlaceTile(metalTile: try resident([cell], quartered: [cell])[cell]!,
                                      placeIn: VisibleTile(tile: cell, worldWrap: 0))
        let context = BuildingCoveragePlanner.plan(groundPlacements: ground + [cellPlacement],
                                                   onFlatMap: true,
                                                   minimumZoom: 14)
        XCTAssertEqual(Set(slots(context)), Set(children))
    }

    /// A cell kept whole cannot leave a quarter out: it draws whole and
    /// the children under it wait, so no building draws twice.
    func testACoarserTileKeptWholeDrawsAndItsChildrenWait() throws {
        let context = plan(resident: try resident([cell] + children.prefix(2)),
                           visible: visible(children),
                           minimumZoom: 14)
        XCTAssertEqual(slots(context), [cell])
        XCTAssertEqual(quarters(of: cell, in: context), TileQuarters.all)
    }

    /// With none of its children in, the cell standing in draws all of
    /// its buildings: no finer tile is there to take them.
    func testACoarserTileStandingInAloneDraws() throws {
        let context = plan(resident: try resident([cell], quartered: [cell]),
                           visible: visible(children),
                           minimumZoom: 14)
        XCTAssertEqual(slots(context), [cell])
        XCTAssertEqual(quarters(of: cell, in: context), TileQuarters.all)
    }

    /// A tileset two zooms deeper than the buildings start: a grandchild
    /// in a quarter whose child is not there waits under the quarter the
    /// cell draws, as a tile under a coarser one drawn whole does.
    func testATileUnderADrawnQuarterWaits() throws {
        let grandchild = Tile(x: 39632, y: 20560, z: 16)
        let ground = [cell, grandchild].map { tile in
            PlaceTile(metalTile: try! resident([tile], quartered: [cell])[tile]!,
                      placeIn: VisibleTile(tile: tile, worldWrap: 0))
        }
        let context = BuildingCoveragePlanner.plan(groundPlacements: ground, onFlatMap: true, minimumZoom: 14)
        XCTAssertEqual(slots(context), [cell])
        XCTAssertEqual(quarters(of: cell, in: context), TileQuarters.all)
    }

    /// Below the buildings' zoom the stand-in draws nothing, and the
    /// children that are in draw theirs.
    func testAStandInCoarserThanTheBuildingsZoomDrawsNone() throws {
        let context = plan(resident: try resident([cell] + children.prefix(2)), visible: visible(children))
        XCTAssertEqual(Set(slots(context)), Set(children.prefix(2)))
    }

    func testAFrameBelowTheBuildingsZoomPlansNone() throws {
        let resident = try resident([cell] + children)
        XCTAssertTrue(plan(resident: resident, visible: visible([cell])).tilePlacements.isEmpty,
                      "A z14 frame under buildings from 15")
        XCTAssertEqual(slots(plan(resident: resident, visible: visible([cell]), minimumZoom: 14)), [cell],
                       "Buildings from 14: the z14 frame draws them")
        let coarse = [VisibleTile(x: cell.x / 2, y: cell.y / 2, z: 13)]
        XCTAssertEqual(slots(plan(resident: resident, visible: coarse, minimumZoom: 0)), [cell],
                       "Coarser than the tiles that carry buildings, never: the z13 frame's ground is the z14 cell standing in, and it draws")
    }

    /// A tile the ground places far from the others draws its buildings
    /// too: the rings decide how far the buildings reach.
    func testAFarTileTheGroundPlacesDrawsItsBuildings() throws {
        let far = Tile(x: (cell.x + 5) * 2, y: cell.y * 2, z: 15)
        let context = plan(resident: try resident(children + [far]), visible: visible(children + [far]))
        XCTAssertEqual(Set(slots(context)), Set(children + [far]))
    }

    /// Each world copy the ground shows draws its own buildings.
    func testWrappedCopiesStayApart() throws {
        let visible = visible(children, worldWrap: 0) + visible(children, worldWrap: 1)
        let context = plan(resident: try resident(children), visible: visible)
        XCTAssertEqual(context.tilePlacements.count, 8)
        XCTAssertEqual(Set(context.tilePlacements.map(\.placeIn.worldWrap)), [0, 1])
    }

    func testTheGlobeHasNoBuildingCoverage() throws {
        let ground = TilePlacementPlanner.buildPlacements(targets: visible(children),
                                                          resident: try resident(children),
                                                          zoom: 15)
        let context = BuildingCoveragePlanner.plan(groundPlacements: ground.tilePlacements, onFlatMap: false)
        XCTAssertTrue(context.tilePlacements.isEmpty)
    }

    func testTheOutputOrderIsDeterministic() throws {
        let context = plan(resident: try resident(children), visible: visible(children.reversed()))
        XCTAssertEqual(slots(context), children.sorted { ($0.x, $0.y) < ($1.x, $1.y) })
    }

    /// The tile zoom the buildings draw from: the whole part of their
    /// camera zoom, within the tileset's zooms, never coarser than 14.
    func testTheDrawZoomFollowsTheSetting() {
        func drawZoom(_ minimumZoom: Double, maximumTileZoom: Int = 15) -> Int {
            var settings = ImmersiveMapSettings.default
            settings.scene.extrusion.buildingsMinimumZoom = minimumZoom
            settings.tiles.coverage.maximumZoomLevel = maximumTileZoom
            return BuildingCoveragePlanner.minimumDrawZoom(settings: settings)
        }
        XCTAssertEqual(drawZoom(15), 15)
        XCTAssertEqual(drawZoom(15.5), 15)
        XCTAssertEqual(drawZoom(17), 15, "The tiles stop at 15: a camera at 17 targets them")
        XCTAssertEqual(drawZoom(12), 14, "Coarser tiles carry merged blocks, never drawn")
        XCTAssertEqual(drawZoom(16, maximumTileZoom: 18), 16)
    }
}
