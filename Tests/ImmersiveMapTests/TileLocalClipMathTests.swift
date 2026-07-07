// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileLocalClipMathTests: XCTestCase {
    func testClipBoundsMirrorsYForNorthWestChild() {
        // Парсер флипует Y: локальный y=0 - южная кромка source-тайла,
        // поэтому северо-западный ребёнок занимает y ∈ [2048, 4096].
        let bounds = TileLocalClipMath.clipBounds(source: Tile(x: 0, y: 0, z: 0),
                                                  placeIn: Tile(x: 0, y: 0, z: 1))
        XCTAssertEqual(bounds, SIMD4<Float>(0, 2048, 2048, 4096))
    }

    func testClipBoundsForSouthEastChild() {
        let bounds = TileLocalClipMath.clipBounds(source: Tile(x: 0, y: 0, z: 0),
                                                  placeIn: Tile(x: 1, y: 1, z: 1))
        XCTAssertEqual(bounds, SIMD4<Float>(2048, 0, 4096, 2048))
    }

    func testClipBoundsAtDepthTwo() {
        let bounds = TileLocalClipMath.clipBounds(source: Tile(x: 0, y: 0, z: 3),
                                                  placeIn: Tile(x: 2, y: 1, z: 5))
        XCTAssertEqual(bounds, SIMD4<Float>(2048, 2048, 3072, 3072))
    }

    func testClipBoundsOffsetSource() {
        // Source не в начале координат: смещение placeIn считается
        // относительно юго-западного угла source.
        let bounds = TileLocalClipMath.clipBounds(source: Tile(x: 3, y: 5, z: 4),
                                                  placeIn: Tile(x: 7, y: 10, z: 5))
        XCTAssertEqual(bounds, SIMD4<Float>(2048, 2048, 4096, 4096))
    }

    func testClipBoundsDisabledForSameTile() {
        let tile = Tile(x: 3, y: 5, z: 4)
        XCTAssertEqual(TileLocalClipMath.clipBounds(source: tile, placeIn: tile),
                       TileLocalClipMath.disabledBounds)
    }
}
