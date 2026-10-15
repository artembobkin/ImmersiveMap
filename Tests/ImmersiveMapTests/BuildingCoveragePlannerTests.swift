// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The building coverage: the tiles the ground shows, from the buildings'
/// zoom on, draw their buildings, each whole in its own square, within the
/// near field. Where a coarser one stands in over ground some of its
/// children already show, it draws and they wait. Nothing coarser than the
/// buildings' zoom draws.
final class BuildingCoveragePlannerTests: XCTestCase {
    private let cell = Tile(x: 9908, y: 5140, z: 14)
    private var children: [Tile] {
        [Tile(x: 19816, y: 10280, z: 15), Tile(x: 19817, y: 10280, z: 15),
         Tile(x: 19816, y: 10281, z: 15), Tile(x: 19817, y: 10281, z: 15)]
    }
    private var eye: SIMD2<Double> {
        SIMD2<Double>(Double(cell.x) + 0.5, Double(cell.y) + 0.5)
    }

    private func resident(_ tiles: [Tile]) throws -> [Tile: MetalTile] {
        var resident: [Tile: MetalTile] = [:]
        for tile in tiles {
            resident[tile] = MetalTile(tile: tile, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
        }
        return resident
    }

    private func visible(_ tiles: [Tile], worldWrap: Int8 = 0) -> [VisibleTile] {
        tiles.map { VisibleTile(tile: $0, worldWrap: worldWrap) }
    }

    /// The buildings over the ground the planner shows for `visible`.
    private func plan(resident: [Tile: MetalTile],
                      visible: [VisibleTile],
                      eye: SIMD2<Double>? = nil,
                      minimumZoom: Int = 15) -> PlaceTilesContext {
        let ground = TilePlacementPlanner.buildPlacements(targets: visible,
                                                          resident: resident,
                                                          zoom: visible.map(\.z).max() ?? 0)
        return BuildingCoveragePlanner.plan(groundPlacements: ground.tilePlacements,
                                            eyeGroundCell: eye ?? self.eye,
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

    /// The cell is resident, two of its children are not: the cell stands
    /// in for them on the ground and draws its buildings whole, and the two
    /// children that are in wait, so no building draws twice and none is
    /// missing until the last child lands.
    func testACoarserTileStandingInDrawsAndItsChildrenWait() throws {
        let context = plan(resident: try resident([cell] + children.prefix(2)),
                           visible: visible(children),
                           minimumZoom: 14)
        XCTAssertEqual(slots(context), [cell])
        XCTAssertTrue(context.tilePlacements.allSatisfy(\.inOwnSlot), "Whole, in its own square")
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

    func testTargetsBeyondTheFieldRadiusAreSkipped() throws {
        let far = Tile(x: (cell.x + 5) * 2, y: cell.y * 2, z: 15)
        let context = plan(resident: try resident(children + [far]), visible: visible(children + [far]))
        XCTAssertEqual(Set(slots(context)), Set(children))
    }

    func testWrappedCopiesStayApart() throws {
        let visible = visible(children, worldWrap: 0) + visible(children, worldWrap: 1)
        let eyeInWorldWrapOne = eye + SIMD2<Double>(Double(1 << 14), 0)
        let context = plan(resident: try resident(children), visible: visible, eye: eyeInWorldWrapOne)
        XCTAssertEqual(Set(context.tilePlacements.map(\.placeIn.worldWrap)), [1])
    }

    func testTheGlobeHasNoBuildingCoverage() throws {
        let ground = TilePlacementPlanner.buildPlacements(targets: visible(children),
                                                          resident: try resident(children),
                                                          zoom: 15)
        let context = BuildingCoveragePlanner.plan(groundPlacements: ground.tilePlacements, eyeGroundCell: nil)
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
