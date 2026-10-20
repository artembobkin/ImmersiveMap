// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// How a tile parsed in layers draws on the relief
/// (`TileWorkingSetSubsystem.drawingOnTheRelief`): a texture without lines,
/// except a stand-in that was on the screen as geometry the frame before
/// and rises by no terrain, which keeps its look.
final class TileWorkingSetReliefLookTests: XCTestCase {
    private let parent = Tile(x: 17, y: 11, z: 5)
    private let child = Tile(x: 34, y: 22, z: 6)

    private func layeredTile(_ tile: Tile) throws -> MetalTile {
        MetalTile(tile: tile, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
    }

    func testAStandInShownAsGeometryKeepsItsGeometryAndLines() throws {
        let standIn = PlaceTile(metalTile: try layeredTile(parent), placeIn: VisibleTile(tile: child))
        let kept = TileWorkingSetSubsystem.drawingOnTheRelief(standIn, shownAsGeometry: [parent])
        XCTAssertNil(kept.rules.raster, "Drawn as it was shown")
        XCTAssertTrue(kept.rules.drawsLines)
    }

    func testAStandInNotShownBeforeDrawsAsATextureWithoutLines() throws {
        let standIn = PlaceTile(metalTile: try layeredTile(parent), placeIn: VisibleTile(tile: child))
        let converted = TileWorkingSetSubsystem.drawingOnTheRelief(standIn, shownAsGeometry: [])
        XCTAssertEqual(converted.rules.raster?.size, TileWorkingSetSubsystem.layeredTileRasterSize)
        XCTAssertFalse(converted.rules.drawsLines)
    }

    func testAStandInBoundToATerrainDrawsAsATexture() throws {
        let standIn = PlaceTile(metalTile: try layeredTile(parent), placeIn: VisibleTile(tile: child), terrain: parent)
        let converted = TileWorkingSetSubsystem.drawingOnTheRelief(standIn, shownAsGeometry: [parent])
        XCTAssertNotNil(converted.rules.raster, "Its square is marked raised, so it draws raised, from a texture")
    }

    func testATileInItsOwnSlotDrawsAsATextureHoweverItWasShown() throws {
        let own = PlaceTile(metalTile: try layeredTile(parent), placeIn: VisibleTile(tile: parent))
        let converted = TileWorkingSetSubsystem.drawingOnTheRelief(own, shownAsGeometry: [parent])
        XCTAssertNotNil(converted.rules.raster, "A ring drawn as geometry below the relief is a raised texture on it")
    }
}
