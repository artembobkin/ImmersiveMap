// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import ModelTileFormat
import XCTest

/// Which level of detail a frame shows, and which model tiles it draws
/// while the tiles of that level are on their way.
final class ModelTilePlannerTests: XCTestCase {
    private typealias Wanted = ModelTileRenderSubsystem.WantedTile
    private typealias Archive = ImmersiveMapSettings.ModelArchiveSettings

    /// A zoom 12 tile, its four zoom 13 tiles and the zoom 14 tiles of the
    /// first of them.
    private static let coarse = Tile(x: 2476, y: 1280, z: 12)
    private static let middle = (0..<4).map { Tile(x: 4952 + $0 % 2, y: 2560 + $0 / 2, z: 13) }
    private static let fine = (0..<4).map { Tile(x: 9904 + $0 % 2, y: 5120 + $0 / 2, z: 14) }

    private func wanted(_ tiles: [Tile], wrap: Int8 = 0) -> [Wanted] {
        tiles.map { Wanted(tile: $0, worldWrap: wrap) }
    }

    private func plan(_ wantedTiles: [Tile],
                      ready: Set<Tile> = [],
                      pending: Set<Tile> = [],
                      loaded: Set<Tile> = []) -> ModelTilePlanner.Plan {
        ModelTilePlanner.plan(wanted: wanted(wantedTiles),
                              state: { ready.contains($0) ? .ready : pending.contains($0) ? .pending : .absent },
                              holdIfLoaded: { loaded.contains($0) })
    }

    // MARK: - The level

    func testTheLevelIsTheCameraZooms() {
        let settings = Archive(minimumZoom: 12, mediumDetailZoom: 14, highDetailZoom: 15.5)

        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 12.5, current: nil, settings: settings), .low)
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 14, current: nil, settings: settings), .medium)
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 15.4, current: nil, settings: settings), .medium)
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 15.5, current: nil, settings: settings), .high)
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 19, current: nil, settings: settings), .high)
    }

    /// Below the models' zoom the level is the one that zoom shows, so its
    /// tiles are the ones loaded when the camera arrives.
    func testBelowTheMinimumZoomTheLevelIsTheOneItShows() {
        let settings = Archive(minimumZoom: 14.5, mediumDetailZoom: 14, highDetailZoom: 16)

        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 12, current: nil, settings: settings), .medium)
    }

    /// A camera resting on a level's zoom keeps the level it has.
    func testALevelReturnsOnlyPastTheMargin() {
        let settings = Archive(minimumZoom: 12, mediumDetailZoom: 14, highDetailZoom: 15.5, detailSwitchMargin: 0.2)

        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 14, current: .low, settings: settings), .medium, "Up at the zoom")
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 13.9, current: .medium, settings: settings), .medium)
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 13.79, current: .medium, settings: settings), .low)
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 15.4, current: .high, settings: settings), .high)
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 13, current: .high, settings: settings), .low, "Two levels at once")
        XCTAssertEqual(ModelTilePlanner.detail(atZoom: 16, current: .low, settings: settings), .high)
    }

    /// An archive baked without a level shows the nearest it has.
    func testAMissingLevelIsTheNearestTheArchiveHolds() {
        XCTAssertEqual(ModelTilePlanner.tileZoom(of: .low, missingZooms: []), 12)
        XCTAssertEqual(ModelTilePlanner.tileZoom(of: .low, missingZooms: [12, 13]), 14, "An archive of zoom 14 alone")
        XCTAssertEqual(ModelTilePlanner.tileZoom(of: .medium, missingZooms: [13]), 14, "A finer one before a coarser")
        XCTAssertEqual(ModelTilePlanner.tileZoom(of: .high, missingZooms: [14]), 13)
        XCTAssertEqual(ModelTilePlanner.tileZoom(of: .high, missingZooms: [13, 14]), 12)
        XCTAssertNil(ModelTilePlanner.tileZoom(of: .medium, missingZooms: [12, 13, 14]))
    }

    // MARK: - The draws

    func testTheLoadedTilesDrawAndThePendingOnesWait() {
        let result = plan(Self.fine, ready: [Self.fine[0], Self.fine[1]], pending: [Self.fine[2]])

        XCTAssertEqual(result.drawn, wanted([Self.fine[0], Self.fine[1]]))
        XCTAssertEqual(result.waiting, [Self.fine[2]], "An empty tile holds nothing back")
    }

    /// Zooming in: the coarser tile on screen stays over all the wanted
    /// tiles under it, the loaded ones too, so no model draws twice, and
    /// no building waits, since its model is drawn.
    func testACoarserTileStandsInUntilEveryTileUnderItIsIn() {
        let waiting = plan(Self.fine, ready: [Self.fine[0]], pending: [Self.fine[1]], loaded: [Self.coarse])
        XCTAssertEqual(waiting.drawn, wanted([Self.coarse]))
        XCTAssertTrue(waiting.waiting.isEmpty)

        let arrived = plan(Self.fine, ready: [Self.fine[0], Self.fine[1]], loaded: [Self.coarse])
        XCTAssertEqual(arrived.drawn, wanted([Self.fine[0], Self.fine[1]]), "All in: the swap is one frame")
    }

    /// The nearest loaded level stands in, and only over its own ground.
    func testTheNearestCoarserTileStandsInOverItsOwnGround() {
        let other = Tile(x: 9906, y: 5120, z: 14)
        let result = plan(Self.fine + [other],
                          ready: [Self.fine[0], other],
                          pending: [Self.fine[1]],
                          loaded: [Self.middle[0]])

        XCTAssertEqual(result.drawn, wanted([Self.middle[0], other]),
                       "The loaded tile under another zoom 13 tile draws as itself")
    }

    /// Zooming out: the finer tiles on screen stay inside a wanted tile
    /// still on its way.
    func testTheFinerTilesStandInForATileOnItsWay() {
        let result = plan([Self.coarse], pending: [Self.coarse], loaded: [Self.middle[1], Self.fine[0], Self.fine[3]])

        XCTAssertEqual(Set(result.drawn), Set(wanted([Self.middle[1], Self.fine[0], Self.fine[3]])))
        XCTAssertTrue(result.waiting.isEmpty)

        let arrived = plan([Self.coarse], ready: [Self.coarse], loaded: [Self.middle[1], Self.fine[0]])
        XCTAssertEqual(arrived.drawn, wanted([Self.coarse]))
    }

    /// A finer tile is not drawn under a loaded one over the same ground.
    func testAFinerTileIsNotDrawnUnderALoadedOne() {
        let result = plan([Self.coarse], pending: [Self.coarse], loaded: [Self.middle[0], Self.fine[0]])

        XCTAssertEqual(result.drawn, wanted([Self.middle[0]]))
    }

    /// A stand-in draws in the copy of the world its wanted tile is in.
    func testAStandInKeepsTheCopyOfTheWorld() {
        let result = ModelTilePlanner.plan(wanted: wanted([Self.fine[0]], wrap: 1),
                                           state: { _ in .pending },
                                           holdIfLoaded: { $0 == Self.coarse })

        XCTAssertEqual(result.drawn, wanted([Self.coarse], wrap: 1))
    }
}
