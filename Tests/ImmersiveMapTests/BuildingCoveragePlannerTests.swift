// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The building coverage: the frame's targets of its target zoom draw
/// their buildings, each in its own place, once resident and within the
/// near field. Nothing coarser stands in for them, and a frame below the
/// buildings' zoom plans none.
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

    private func plan(resident: [Tile: MetalTile],
                      visible: [VisibleTile],
                      eye: SIMD2<Double>? = nil,
                      minimumZoom: Int = 15) -> PlaceTilesContext {
        BuildingCoveragePlanner.plan(resident: resident,
                                     visibleTiles: visible,
                                     eyeGroundCell: eye ?? self.eye,
                                     minimumZoom: minimumZoom)
    }

    private func slots(_ context: PlaceTilesContext) -> [Tile] {
        context.tilePlacements.map(\.placeIn.tile)
    }

    func testTheResidentTargetsDrawInTheirOwnPlaces() throws {
        let context = plan(resident: try resident([cell] + children.prefix(2)), visible: visible(children))
        XCTAssertEqual(Set(slots(context)), Set(children.prefix(2)))
        XCTAssertTrue(context.tilePlacements.allSatisfy(\.inOwnSlot))
    }

    /// The cell is resident, two of its children are not: the cell draws
    /// no buildings in their places, they stay empty until they arrive.
    func testACoarserTileNeverStandsInForAMissingTarget() throws {
        let context = plan(resident: try resident([cell] + children.prefix(2)), visible: visible(children))
        XCTAssertFalse(context.tilePlacements.contains { $0.metalTile.tile == cell })
    }

    func testAFrameBelowTheBuildingsZoomPlansNone() throws {
        let resident = try resident([cell] + children)
        XCTAssertTrue(plan(resident: resident, visible: visible([cell])).tilePlacements.isEmpty,
                      "A z14 frame under buildings from 15")
        XCTAssertEqual(slots(plan(resident: resident, visible: visible([cell]), minimumZoom: 14)), [cell],
                       "Buildings from 14: the z14 frame draws them")
        let coarse = [VisibleTile(x: cell.x / 2, y: cell.y / 2, z: 13)]
        XCTAssertTrue(plan(resident: resident, visible: coarse, minimumZoom: 0).tilePlacements.isEmpty,
                      "Coarser than the tiles that carry buildings, never")
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
        let context = BuildingCoveragePlanner.plan(resident: try resident(children),
                                                   visibleTiles: visible(children),
                                                   eyeGroundCell: nil)
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
