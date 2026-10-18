// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The flat map's horizon backdrop: the world tile under every placement,
/// once per world copy, flat, a small texture without lines or labels.
final class HorizonBackdropTests: XCTestCase {
    func testTheBackdropIsTheWorldTileOncePerWorldCopy() throws {
        let world = MetalTile(tile: TileWorkingSetSubsystem.horizonBackdropTile,
                              tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
        let targets = [VisibleTile(x: 3, y: 2, z: 4, worldWrap: 0),
                       VisibleTile(x: 15, y: 2, z: 4, worldWrap: -1),
                       VisibleTile(x: 4, y: 2, z: 4, worldWrap: 0)]
        let backdrops = TileWorkingSetSubsystem.horizonBackdrops(targets: targets, resident: [world.tile: world])

        XCTAssertEqual(backdrops.map(\.placeIn), [VisibleTile(x: 0, y: 0, z: 0, worldWrap: -1),
                                                   VisibleTile(x: 0, y: 0, z: 0, worldWrap: 0)])
        for backdrop in backdrops {
            XCTAssertTrue(backdrop.isHorizonBackdrop)
            XCTAssertTrue(backdrop.inOwnSlot)
            XCTAssertFalse(backdrop.rules.drawsLines)
            XCTAssertFalse(backdrop.rules.drawsLabels)
            XCTAssertEqual(backdrop.rules.raster?.size, TileWorkingSetSubsystem.horizonBackdropRasterSize)
        }
        XCTAssertEqual(TileWorkingSetSubsystem.horizonBackdropTile, Tile(x: 0, y: 0, z: 0))
        XCTAssertTrue(TileWorkingSetSubsystem.horizonBackdrops(targets: targets, resident: [:]).isEmpty,
                      "Nothing while the world tile is not resident")
        XCTAssertFalse(PlaceTile(metalTile: world, placeIn: VisibleTile(tile: world.tile)).isHorizonBackdrop,
                       "A placement is the backdrop only when placed as one")
    }
}
