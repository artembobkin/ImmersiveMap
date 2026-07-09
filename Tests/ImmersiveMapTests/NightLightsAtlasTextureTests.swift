// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

final class NightLightsAtlasTextureTests: XCTestCase {
    func testSingleTileBuildsAtlasMetadata() throws {
        let atlas = try makeAtlas(pageSize: 2048, tileSize: 1024)
        let state = atlas.update(tiles: [makeTileData(tile: Tile(x: 1, y: 2, z: 3))])

        XCTAssertEqual(state.pages.count, 1)
        XCTAssertEqual(state.entries, [
            NightLightsAtlasEntry(tile: Tile(x: 1, y: 2, z: 3),
                                  pageIndex: 0,
                                  uvOrigin: SIMD2<Float>(0.0, 0.0),
                                  uvScale: SIMD2<Float>(0.5, 0.5))
        ])
    }

    func testMultipleTilesPackRowMajorAcrossPages() throws {
        let atlas = try makeAtlas(pageSize: 2048, tileSize: 1024)
        let tiles = (0..<5).map { makeTileData(tile: Tile(x: $0, y: 0, z: 4)) }

        let state = atlas.update(tiles: tiles)

        XCTAssertEqual(state.pages.count, 2)
        XCTAssertEqual(state.entries.map(\.pageIndex), [0, 0, 0, 0, 1])
        XCTAssertEqual(state.entries.map(\.uvOrigin), [
            SIMD2<Float>(0.0, 0.0),
            SIMD2<Float>(0.5, 0.0),
            SIMD2<Float>(0.0, 0.5),
            SIMD2<Float>(0.5, 0.5),
            SIMD2<Float>(0.0, 0.0)
        ])
        XCTAssertEqual(state.entries.map(\.uvScale), Array(repeating: SIMD2<Float>(0.5, 0.5), count: 5))
    }

    func testUpdateKeepsExistingTileSlotWhenVisibleSetChanges() throws {
        let atlas = try makeAtlas(pageSize: 4, tileSize: 2)
        let tileA = Tile(x: 0, y: 0, z: 1)
        let tileB = Tile(x: 1, y: 0, z: 1)
        let tileC = Tile(x: 0, y: 1, z: 1)
        let tileD = Tile(x: 1, y: 1, z: 1)
        let initialState = atlas.update(tiles: [
            makeTileData(tile: tileA, width: 2, height: 2, bytes: interleavedBytes(core: 1, halo: 101, pixelCount: 4)),
            makeTileData(tile: tileB, width: 2, height: 2, bytes: interleavedBytes(core: 2, halo: 102, pixelCount: 4)),
            makeTileData(tile: tileC, width: 2, height: 2, bytes: interleavedBytes(core: 3, halo: 103, pixelCount: 4))
        ])
        let originalBEntry = try XCTUnwrap(initialState.entries.first { $0.tile == tileB })

        let updatedState = atlas.update(tiles: [
            makeTileData(tile: tileB, width: 2, height: 2, bytes: interleavedBytes(core: 2, halo: 102, pixelCount: 4)),
            makeTileData(tile: tileD, width: 2, height: 2, bytes: interleavedBytes(core: 4, halo: 104, pixelCount: 4))
        ])

        let updatedBEntry = try XCTUnwrap(updatedState.entries.first { $0.tile == tileB })
        let updatedDEntry = try XCTUnwrap(updatedState.entries.first { $0.tile == tileD })
        XCTAssertEqual(updatedBEntry.uvOrigin, originalBEntry.uvOrigin)
        XCTAssertEqual(updatedBEntry.pageIndex, originalBEntry.pageIndex)
        XCTAssertEqual(updatedDEntry.uvOrigin, SIMD2<Float>(0.0, 0.0))
    }

    func testInvalidTilesAreSkipped() throws {
        let atlas = try makeAtlas(pageSize: 2048, tileSize: 1024)
        let validTile = makeTileData(tile: Tile(x: 1, y: 0, z: 4))
        let wrongWidth = NightLightsTileData(tile: Tile(x: 2, y: 0, z: 4),
                                            width: 512,
                                            height: 1024,
                                            bytes: [UInt8](repeating: 1, count: 512 * 1024 * 2))
        let wrongByteCount = NightLightsTileData(tile: Tile(x: 3, y: 0, z: 4),
                                                width: 1024,
                                                height: 1024,
                                                bytes: [UInt8](repeating: 1, count: 1024 * 1024))

        let state = atlas.update(tiles: [wrongWidth, validTile, wrongByteCount])

        XCTAssertEqual(state.pages.count, 1)
        XCTAssertEqual(state.entries.map(\.tile), [validTile.tile])
        XCTAssertEqual(state.entries.first?.uvOrigin, SIMD2<Float>(0.0, 0.0))
    }

    func testEmptyUpdateReturnsEmptyAfterPreviousNonEmptyUpdate() throws {
        let atlas = try makeAtlas(pageSize: 2048, tileSize: 1024)
        _ = atlas.update(tiles: [makeTileData(tile: Tile(x: 1, y: 0, z: 4))])

        let state = atlas.update(tiles: [])

        XCTAssertTrue(state.pages.isEmpty)
        XCTAssertTrue(state.entries.isEmpty)
    }

    func testNightLightsAtlasEntryUniformLayoutMatchesMetal() {
        XCTAssertEqual(MemoryLayout<NightLightsAtlasEntryUniform>.stride, 32)
        XCTAssertEqual(MemoryLayout<NightLightsAtlasEntryUniform>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NightLightsAtlasEntryUniform>.offset(of: \.tileAndPage), 0)
        XCTAssertEqual(MemoryLayout<NightLightsAtlasEntryUniform>.offset(of: \.uvOriginAndScale), 16)
    }

    func testNightLightsAtlasEntryUniformAccessorsMapPackedFields() {
        let uniform = NightLightsAtlasEntryUniform(tile: SIMD3<Int32>(1, 2, 3),
                                                   pageIndex: 4,
                                                   uvOrigin: SIMD2<Float>(0.25, 0.5),
                                                   uvScale: SIMD2<Float>(0.125, 0.25))

        XCTAssertEqual(uniform.tileAndPage, SIMD4<Int32>(1, 2, 3, 4))
        XCTAssertEqual(uniform.uvOriginAndScale, SIMD4<Float>(0.25, 0.5, 0.125, 0.25))
        XCTAssertEqual(uniform.tile, SIMD3<Int32>(1, 2, 3))
        XCTAssertEqual(uniform.pageIndex, 4)
        XCTAssertEqual(uniform.uvOrigin, SIMD2<Float>(0.25, 0.5))
        XCTAssertEqual(uniform.uvScale, SIMD2<Float>(0.125, 0.25))
    }

    func testNightLightsAtlasSurfaceBindingCapsPagesAndEntries() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        let pages = (0..<(NightLightsAtlasSurfaceBinding.maxPageCount + 2)).compactMap { index in
            makeTexture(device: device, label: "NightLightsTestPage\(index)")
        }
        let invalidEntry = NightLightsAtlasEntry(tile: Tile(x: 999, y: 999, z: 6),
                                                 pageIndex: NightLightsAtlasSurfaceBinding.maxPageCount + 1,
                                                 uvOrigin: SIMD2<Float>(0, 0),
                                                 uvScale: SIMD2<Float>(0.25, 0.25))
        let generatedEntries: [NightLightsAtlasEntry] = (0..<(NightLightsAtlasSurfaceBinding.maxEntryCount + 2)).map { index in
            NightLightsAtlasEntry(tile: Tile(x: index, y: index + 1, z: 6),
                                  pageIndex: index % NightLightsAtlasSurfaceBinding.maxPageCount,
                                  uvOrigin: SIMD2<Float>(Float(index), Float(index + 1)),
                                  uvScale: SIMD2<Float>(0.25, 0.25))
        }
        let entries: [NightLightsAtlasEntry] = [invalidEntry] + generatedEntries

        let binding = NightLightsAtlasSurfaceBinding(state: NightLightsAtlasState(pages: pages,
                                                                                  entries: entries))

        XCTAssertEqual(binding.pages.count, NightLightsAtlasSurfaceBinding.maxPageCount)
        XCTAssertEqual(binding.entryUniforms.count, NightLightsAtlasSurfaceBinding.maxEntryCount)
        XCTAssertEqual(binding.entryUniforms.first?.tileAndPage, SIMD4<Int32>(0, 1, 6, 0))
        XCTAssertEqual(binding.entryUniforms.last?.tile.x, Int32(NightLightsAtlasSurfaceBinding.maxEntryCount - 1))
        XCTAssertFalse(binding.entryUniforms.contains { $0.tile.x == 999 })
    }

    func testNightLightsAtlasSurfaceBindingShaderBudgetContract() {
        XCTAssertEqual(NightLightsAtlasSurfaceBinding.maxPageCount, 8)
        XCTAssertEqual(NightLightsAtlasSurfaceBinding.maxEntryCount, 128)
        XCTAssertLessThanOrEqual(NightLightsAtlasSurfaceBinding.maxEntryCount *
                                 MemoryLayout<NightLightsAtlasEntryUniform>.stride,
                                 4096)
    }

    func testInvalidInitializerParametersFallBackToDefaultAtlasGeometry() throws {
        let invalidInputs = [
            (pageSize: 0, tileSize: 1024),
            (pageSize: 4096, tileSize: 0),
            (pageSize: 512, tileSize: 1024),
            (pageSize: 3000, tileSize: 1024),
            (pageSize: Int.max - 1, tileSize: 1),
            (pageSize: Int.max, tileSize: Int.max)
        ]

        for input in invalidInputs {
            let atlas = try makeAtlas(pageSize: input.pageSize, tileSize: input.tileSize)

            let state = atlas.update(tiles: [makeTileData(tile: Tile(x: 1, y: 0, z: 4))])

            XCTAssertEqual(state.pages.count, 1)
            XCTAssertEqual(state.entries.first?.uvOrigin, SIMD2<Float>(0.0, 0.0))
            XCTAssertEqual(state.entries.first?.uvScale, SIMD2<Float>(0.25, 0.25))
        }
    }

    func testUploadsTwoChannelTilesIntoPublishedSlots() throws {
        let atlas = try makeAtlas(pageSize: 4, tileSize: 2)
        let tiles = [
            makeTileData(tile: Tile(x: 0, y: 0, z: 1),
                         width: 2,
                         height: 2,
                         bytes: [
                            1, 101, 2, 102,
                            3, 103, 4, 104
                         ]),
            makeTileData(tile: Tile(x: 1, y: 0, z: 1),
                         width: 2,
                         height: 2,
                         bytes: [
                            5, 105, 6, 106,
                            7, 107, 8, 108
                         ]),
            makeTileData(tile: Tile(x: 0, y: 1, z: 1),
                         width: 2,
                         height: 2,
                         bytes: [
                            9, 109, 10, 110,
                            11, 111, 12, 112
                         ])
        ]

        let state = atlas.update(tiles: tiles)

        let page = try XCTUnwrap(state.pages.first)
        XCTAssertEqual(page.pixelFormat, .rg8Unorm)

        XCTAssertEqual(readTileBytes(from: page, originX: 0, originY: 0), [
            1, 101, 2, 102,
            3, 103, 4, 104
        ])
        XCTAssertEqual(readTileBytes(from: page, originX: 2, originY: 0), [
            5, 105, 6, 106,
            7, 107, 8, 108
        ])
        XCTAssertEqual(readTileBytes(from: page, originX: 0, originY: 2), [
            9, 109, 10, 110,
            11, 111, 12, 112
        ])
    }

    private func makeAtlas(pageSize: Int, tileSize: Int) throws -> NightLightsAtlasTexture {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        return NightLightsAtlasTexture(device: device, pageSize: pageSize, tileSize: tileSize)
    }

    private func makeTexture(device: MTLDevice, label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm,
                                                                  width: 4,
                                                                  height: 4,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }

    private func readTileBytes(from page: MTLTexture, originX: Int, originY: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: 2 * 2 * 2)
        page.getBytes(&bytes,
                      bytesPerRow: 2 * 2,
                      from: MTLRegionMake2D(originX, originY, 2, 2),
                      mipmapLevel: 0)
        return bytes
    }

    private func makeTileData(tile: Tile) -> NightLightsTileData {
        makeTileData(tile: tile,
                     width: 1024,
                     height: 1024,
                     bytes: interleavedBytes(core: UInt8(tile.x),
                                             halo: UInt8(truncatingIfNeeded: tile.x + 128),
                                             pixelCount: 1024 * 1024))
    }

    private func makeTileData(tile: Tile, width: Int, height: Int, bytes: [UInt8]) -> NightLightsTileData {
        NightLightsTileData(tile: tile,
                            width: width,
                            height: height,
                            bytes: bytes)
    }

    private func interleavedBytes(core: UInt8, halo: UInt8, pixelCount: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(pixelCount * 2)
        for _ in 0..<pixelCount {
            bytes.append(core)
            bytes.append(halo)
        }
        return bytes
    }
}
