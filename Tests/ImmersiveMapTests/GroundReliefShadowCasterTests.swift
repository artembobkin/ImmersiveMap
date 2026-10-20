// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import simd
import XCTest

/// The mountains' casters: every point of the ground casts once, from the
/// placement the tile-priority stencil shows there.
final class GroundReliefShadowCasterTests: XCTestCase {
    func testACoarseSquareCastsOnlyAroundTheFinerOnesInside() throws {
        let parent = try placement(source: Tile(x: 2, y: 3, z: 8), placeIn: Tile(x: 2, y: 3, z: 8), slot: 8)
        let child = try placement(source: Tile(x: 9, y: 13, z: 10), placeIn: Tile(x: 9, y: 13, z: 10), slot: 10)

        let casters = PlacementGroundSquare.squares(of: [parent, child])

        let parentSquares = Set(casters.filter { $0.source.tile == parent.metalTile.tile }.map(\.square.tile))
        XCTAssertEqual(parentSquares, [Tile(x: 5, y: 6, z: 9),
                                       Tile(x: 4, y: 7, z: 9),
                                       Tile(x: 5, y: 7, z: 9),
                                       Tile(x: 8, y: 12, z: 10),
                                       Tile(x: 9, y: 12, z: 10),
                                       Tile(x: 8, y: 13, z: 10)],
                       "The parent casts the largest squares that hold no finer placement")
        XCTAssertEqual(casters.filter { $0.source.tile == child.metalTile.tile }.map(\.square.tile),
                       [child.placeIn.tile],
                       "The finer placement casts its own square")
    }

    func testAPlacementSharingASquareCastsOnce() throws {
        let first = try placement(source: Tile(x: 4, y: 6, z: 9), placeIn: Tile(x: 8, y: 12, z: 10), slot: 10)
        let last = try placement(source: Tile(x: 8, y: 12, z: 10), placeIn: Tile(x: 8, y: 12, z: 10), slot: 10)

        let casters = PlacementGroundSquare.squares(of: [first, last])

        XCTAssertEqual(casters.map(\.source.tile), [last.metalTile.tile],
                       "The last mark of a square is the one the stencil keeps")
    }

    func testASourceRisesByTheFinestTerrainItIsPlacedWith() throws {
        let source = Tile(x: 4, y: 6, z: 9)
        let fine = Tile(x: 4, y: 6, z: 9)
        let coarse = Tile(x: 2, y: 3, z: 8)
        let near = try placement(source: source, placeIn: Tile(x: 8, y: 12, z: 10), slot: 10, terrain: fine)
        let far = try placement(source: source, placeIn: Tile(x: 9, y: 12, z: 10), slot: 9, terrain: coarse)

        let casters = PlacementGroundSquare.squares(of: [near, far])

        XCTAssertEqual(Set(casters.map(\.source.displacement)), [fine],
                       "As the ground draws it, the source takes the finest terrain of its placements")
    }

    func testANarrowedReliefReadsTheSameHeights() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is required for a terrain tile.")
        }
        let size = 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let metres = (0 ..< size * size).map { Float($0 * 10) }
        let terrain = GroundReliefTile(texture: texture,
                                       size: size,
                                       halves: GroundReliefEdgeWeld.halves(metres),
                                       heightRange: 0 ... 150)
        let tile = Tile(x: 0, y: 0, z: 1)
        let part = Tile(x: 1, y: 1, z: 2)
        let relief = GroundRelief(terrain: terrain, origin: .zero, scale: 1, strength: 1)

        let narrowed = relief.narrowed(to: part, in: tile)

        for uv in [SIMD2<Float>(0, 0), SIMD2<Float>(0.5, 0.25), SIMD2<Float>(1, 1)] {
            XCTAssertEqual(narrowed.metres(atTileUV: uv),
                           relief.metres(atTileUV: SIMD2<Float>(0.5, 0.5) + uv * 0.5),
                           accuracy: 1e-3)
        }
    }

    /// A square takes its source's cells over the part of the source it
    /// is, on the source's lines, and never none.
    func testASquareTakesItsSourcesCellsOverItsPart() {
        XCTAssertEqual(PlacementGroundSquare.cells(ofSource: 256, sourceZoom: 8, squareZoom: 8), 256)
        XCTAssertEqual(PlacementGroundSquare.cells(ofSource: 256, sourceZoom: 8, squareZoom: 10), 64)
        XCTAssertEqual(PlacementGroundSquare.cells(ofSource: 2, sourceZoom: 8, squareZoom: 12), 1)
    }

    private func placement(source: Tile, placeIn: Tile, slot: Int, terrain: Tile? = nil) throws -> PlaceTile {
        let metalTile = MetalTile(tile: source, tileBuffers: try TileBuffersFixtures.makeEmptyTileBuffers())
        let square = VisibleTile(tile: placeIn)
        let slotTile = placeIn.findParentTile(atZoom: min(slot, placeIn.z)) ?? placeIn
        return PlaceTile(metalTile: metalTile, placeIn: square, slot: VisibleTile(tile: slotTile), terrain: terrain)
    }
}
