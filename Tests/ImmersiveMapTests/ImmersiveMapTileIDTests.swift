// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The public name of a tile and the box of degrees it and the tile
/// grid's selectable area are stated in.
final class ImmersiveMapTileIDTests: XCTestCase {
    func testTheNumbersAreBroughtIntoTheMap() {
        XCTAssertEqual(ImmersiveMapTileID(zoom: 2, x: 5, y: 9), ImmersiveMapTileID(zoom: 2, x: 1, y: 3))
        XCTAssertEqual(ImmersiveMapTileID(zoom: 2, x: -1, y: -4), ImmersiveMapTileID(zoom: 2, x: 3, y: 0))
        XCTAssertEqual(ImmersiveMapTileID(zoom: -3, x: 7, y: 7), ImmersiveMapTileID(zoom: 0, x: 0, y: 0))
        XCTAssertEqual(ImmersiveMapTileID(zoom: 99, x: 0, y: 0).zoom, ImmersiveMapTileID.maximumZoom)
        XCTAssertEqual(ImmersiveMapTileID(zoom: 15, x: 19295, y: 24641).description, "15/19295/24641")
    }

    func testTheTileThatHoldsACoordinate() {
        // Manhattan, in the tile every web map names for it.
        let tile = ImmersiveMapTileID(containing: GeoCoordinate(latitude: 40.7128, longitude: -74.0060), zoom: 15)
        XCTAssertEqual(tile, ImmersiveMapTileID(zoom: 15, x: 9647, y: 12320))
        XCTAssertEqual(ImmersiveMapTileID(containing: GeoCoordinate(latitude: 89, longitude: 179.999), zoom: 3),
                       ImmersiveMapTileID(zoom: 3, x: 7, y: 0), "Past the map's edge is the edge's tile")
        XCTAssertEqual(ImmersiveMapTileID(containing: GeoCoordinate(latitude: -89, longitude: -180), zoom: 3),
                       ImmersiveMapTileID(zoom: 3, x: 0, y: 7))
    }

    func testATileHoldsItsOwnCentre() {
        for tile in [ImmersiveMapTileID(zoom: 0, x: 0, y: 0),
                     ImmersiveMapTileID(zoom: 5, x: 31, y: 0),
                     ImmersiveMapTileID(zoom: 15, x: 19295, y: 24641)] {
            XCTAssertEqual(ImmersiveMapTileID(containing: tile.center, zoom: tile.zoom), tile)
            XCTAssertTrue(tile.bounds.contains(tile.center))
            XCTAssertLessThan(tile.bounds.southWest.latitude, tile.bounds.northEast.latitude)
            XCTAssertLessThan(tile.bounds.southWest.longitude, tile.bounds.northEast.longitude)
        }
        let world = ImmersiveMapTileID(zoom: 0, x: 0, y: 0).bounds
        XCTAssertEqual(world.southWest.longitude, -180)
        XCTAssertEqual(world.northEast.longitude, 180)
        XCTAssertEqual(world.northEast.latitude, 85.0511, accuracy: 1e-3)
    }

    func testTheParentAndTheChildren() {
        let tile = ImmersiveMapTileID(zoom: 3, x: 5, y: 2)
        XCTAssertEqual(tile.parent, ImmersiveMapTileID(zoom: 2, x: 2, y: 1))
        XCTAssertNil(ImmersiveMapTileID(zoom: 0, x: 0, y: 0).parent)
        XCTAssertEqual(tile.children, [ImmersiveMapTileID(zoom: 4, x: 10, y: 4), ImmersiveMapTileID(zoom: 4, x: 11, y: 4),
                                       ImmersiveMapTileID(zoom: 4, x: 10, y: 5), ImmersiveMapTileID(zoom: 4, x: 11, y: 5)])
        XCTAssertTrue(tile.children.allSatisfy { $0.parent == tile })
        XCTAssertTrue(ImmersiveMapTileID(zoom: ImmersiveMapTileID.maximumZoom, x: 0, y: 0).children.isEmpty)
    }

    func testATileSurvivesCoding() throws {
        let tile = ImmersiveMapTileID(zoom: 15, x: 19295, y: 24641)
        let decoded = try JSONDecoder().decode(ImmersiveMapTileID.self, from: JSONEncoder().encode(tile))
        XCTAssertEqual(decoded, tile)
    }

    // MARK: - The box

    private func box(_ south: Double, _ west: Double, _ north: Double, _ east: Double) -> ImmersiveMapGeoBounds {
        ImmersiveMapGeoBounds(southWest: GeoCoordinate(latitude: south, longitude: west),
                              northEast: GeoCoordinate(latitude: north, longitude: east))
    }

    func testABoxHoldsWhatLiesInIt() {
        let bounds = box(40, -75, 41, -73)
        XCTAssertTrue(bounds.contains(GeoCoordinate(latitude: 40.5, longitude: -74)))
        XCTAssertTrue(bounds.contains(GeoCoordinate(latitude: 40, longitude: -75)), "The edges are the box's")
        XCTAssertFalse(bounds.contains(GeoCoordinate(latitude: 40.5, longitude: -72)))
        XCTAssertFalse(bounds.contains(GeoCoordinate(latitude: 42, longitude: -74)))
    }

    func testABoxAcrossTheAntimeridian() {
        let bounds = box(-10, 170, 10, -170)
        XCTAssertTrue(bounds.contains(GeoCoordinate(latitude: 0, longitude: 175)))
        XCTAssertTrue(bounds.contains(GeoCoordinate(latitude: 0, longitude: -175)))
        XCTAssertTrue(bounds.contains(GeoCoordinate(latitude: 0, longitude: 180)))
        XCTAssertFalse(bounds.contains(GeoCoordinate(latitude: 0, longitude: 0)))
        XCTAssertTrue(bounds.intersects(box(-5, -179, 5, -160)))
        XCTAssertTrue(bounds.intersects(box(-5, 160, 5, 171)))
        XCTAssertFalse(bounds.intersects(box(-5, -160, 5, 160)))
    }

    func testBoxesThatOnlyTouchDoNotOverlap() {
        let bounds = box(0, 0, 10, 10)
        XCTAssertTrue(bounds.intersects(box(0, 10, 10, 20)), "A shared edge is a point in common")
        XCTAssertFalse(bounds.overlaps(box(0, 10, 10, 20)), "And no shared area")
        XCTAssertTrue(bounds.overlaps(box(5, 5, 15, 15)))
        XCTAssertFalse(bounds.overlaps(box(20, 0, 30, 10)))
        // A tile beside a box drawn along its edge is outside it.
        let tile = ImmersiveMapTileID(zoom: 4, x: 8, y: 7)
        let neighbour = ImmersiveMapTileID(zoom: 4, x: 9, y: 7)
        XCTAssertTrue(tile.bounds.overlaps(tile.bounds))
        XCTAssertFalse(tile.bounds.overlaps(neighbour.bounds))
    }
}
