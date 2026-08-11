// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// End-to-end checks of the arena-image cache path against a real GPU: the
/// blob the codec stores must byte-match the arena the factory builds from
/// the same parse, a decoded image must materialize into an identical tile,
/// and on Metal 3 devices the MTLIO container written by the render-side
/// transport must DMA-load back into the arena byte for byte.
final class TileArenaImageMaterializeTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        return device
    }

    /// A tile exercising every span kind: ground geometry, one road phase,
    /// extruded geometry, glyph and icon runs, road label glyphs.
    private func makeRichPreparedTile(tile: Tile) -> PreparedTileCPU {
        let ground = PreparedTileCPU.GeometryLayer(
            vertices: (0..<7).map { TilePipeline.VertexIn(position: SIMD2<Int16>(Int16($0), Int16($0 * 2)), styleIndex: 0) },
            indices: [0, 1, 2, 2, 3, 4, 4, 5, 6],
            styles: [TilePolygonStyle(color: SIMD4<Float>(0.2, 0.4, 0.6, 1))],
            overviewStyleMasks: [1]
        )
        let roadFill = PreparedTileCPU.GeometryLayer(
            vertices: (0..<4).map { TilePipeline.VertexIn(position: SIMD2<Int16>(Int16($0 * 3), 9), styleIndex: 0) },
            indices: [0, 1, 2, 1, 2, 3],
            styles: [TilePolygonStyle(color: SIMD4<Float>(0.5, 0.5, 0.5, 1))],
            overviewStyleMasks: [0]
        )
        let emptyLayer = PreparedTileCPUTestFixtures.emptyGeometryLayer()
        let groundPhases = RoadGeometryPhases(shadow: emptyLayer,
                                              casing: emptyLayer,
                                              fill: roadFill,
                                              detail: emptyLayer,
                                              overlay: emptyLayer)
        let emptyPhases = RoadGeometryPhases(shadow: emptyLayer,
                                             casing: emptyLayer,
                                             fill: emptyLayer,
                                             detail: emptyLayer,
                                             overlay: emptyLayer)
        let glyphVertices = (0..<5).map { index in
            LabelVertex(position: SIMD2<Float>(Float(index), 1),
                        uv: SIMD2<Float>(0.5, 0.5),
                        labelIndex: Int32(index),
                        spriteUV: SIMD2<Float>(0, 0))
        }
        let style = LabelTextStyle(key: 1,
                                   fillColor: SIMD3<Float>(1, 1, 1),
                                   strokeColor: SIMD3<Float>(0, 0, 0),
                                   strokeWidthPx: 1,
                                   sizePx: 14,
                                   weight: .bold)
        let fullSet = PreparedTileCPU.TextLabelSet(
            placementInputs: [],
            glyphRuns: [PreparedTileCPU.TextGlyphRun(style: style, localGlyphVertices: glyphVertices)],
            poiIconRuns: [PreparedTileCPU.PoiIconRun(style: style, localIconVertices: Array(glyphVertices.prefix(3)))]
        )
        let emptySet = PreparedTileCPU.TextLabelSet(placementInputs: [], glyphRuns: [], poiIconRuns: [])
        return PreparedTileCPU(
            tile: tile,
            ground: ground,
            roads: RoadStructureBuckets(tunnel: emptyPhases, ground: groundPhases, bridge: emptyPhases),
            bridgeOverlay: emptyLayer,
            extruded: PreparedTileCPU.Extruded(
                vertices: [],
                indices: [],
                styles: []
            ),
            textLabels: PreparedTileCPU.TextLabels(full: fullSet, reduced: emptySet, minimal: emptySet),
            roadLabels: PreparedTileCPU.RoadLabels(pathInputs: [],
                                                   pathRanges: [],
                                                   pathLabels: [],
                                                   labelStyle: style,
                                                   localGlyphVertices: Array(glyphVertices.prefix(2)),
                                                   glyphBounds: [],
                                                   glyphBoundRanges: [],
                                                   sizes: [],
                                                   anchorRanges: [],
                                                   anchors: [])
        )
    }

    private func arenaBytes(of metalTile: MetalTile) throws -> Data {
        let buffer = try XCTUnwrap(metalTile.tileBuffers.backingBuffer)
        return Data(bytes: buffer.contents(), count: buffer.length)
    }

    func testFactoryArenaMatchesImagePlanBlobByteForByte() throws {
        let device = try makeDevice()
        guard device.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct buffer readback")
        }
        let tile = Tile(x: 1, y: 2, z: 12)
        let preparedTile = makeRichPreparedTile(tile: tile)

        let factory = MetalTileFactory(metalDevice: device)
        let metalTile = try XCTUnwrap(factory.makeTile(from: preparedTile))

        let plan = TileArenaImageMath.plan(for: preparedTile)
        var blob = Data(count: plan.totalByteCount)
        blob.withUnsafeMutableBytes { bytes in
            TileArenaImageMath.writeBlob(plan: plan, into: bytes.baseAddress!)
        }

        XCTAssertEqual(try arenaBytes(of: metalTile), blob,
                       "The codec blob and the factory arena must be the same bytes")
    }

    func testInlineImageMaterializesIdenticalTile() async throws {
        let device = try makeDevice()
        guard device.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct buffer readback")
        }
        let tile = Tile(x: 5, y: 6, z: 12)
        let preparedTile = makeRichPreparedTile(tile: tile)
        let cacheIdentity = makeCacheIdentity()

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity)
        let hit = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: URL(fileURLWithPath: "/nonexistent"))

        let factory = MetalTileFactory(metalDevice: device)
        let parsed = try XCTUnwrap(factory.makeTile(from: preparedTile))
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .tile(let materialized) = result else {
            return XCTFail("The inline image must materialize, got \(result)")
        }

        XCTAssertEqual(try arenaBytes(of: materialized), try arenaBytes(of: parsed))
        XCTAssertEqual(materialized.tileBuffers.ground.verticesCount,
                       parsed.tileBuffers.ground.verticesCount)
        XCTAssertEqual(materialized.tileBuffers.ground.indexType, parsed.tileBuffers.ground.indexType)
        XCTAssertEqual(materialized.tileBuffers.roads.ground.fill.indicesCount,
                       parsed.tileBuffers.roads.ground.fill.indicesCount)
        XCTAssertEqual(materialized.tileBuffers.textLabels.full.labelsByStyleRuns.first?.localGlyphVertexCount,
                       parsed.tileBuffers.textLabels.full.labelsByStyleRuns.first?.localGlyphVertexCount)
        XCTAssertEqual(materialized.tileBuffers.roadLabels.localGlyphVertexCount,
                       parsed.tileBuffers.roadLabels.localGlyphVertexCount)
    }

    func testMTLIOContainerRoundTripsThroughFileBlobMaterialize() async throws {
        let device = try makeDevice()
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: device) else {
            throw XCTSkip("MTLIO requires a Metal 3 device outside the simulator")
        }
        guard device.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct buffer readback")
        }
        let tile = Tile(x: 9, y: 10, z: 12)
        let preparedTile = makeRichPreparedTile(tile: tile)
        let cacheIdentity = makeCacheIdentity()

        let blobURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileArenaImage-\(UUID().uuidString).ptgeo")
        defer { try? FileManager.default.removeItem(at: blobURL) }

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobTransport: .file)
        try MTLIOPreparedTileGeometryTransport().writeBlobFile(encoded.fileBlob, to: blobURL)

        let hit = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: blobURL)
        guard case .file = hit.image.blob else {
            return XCTFail("The file-transport entry must carry a file blob")
        }

        let factory = MetalTileFactory(metalDevice: device)
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .tile(let materialized) = result else {
            return XCTFail("The MTLIO load must materialize, got \(result)")
        }

        XCTAssertEqual(try arenaBytes(of: materialized), encoded.fileBlob,
                       "The DMA-loaded arena must byte-match the blob the container was written from")
    }

    func testMissingBlobFileFailsAsUnreadableImage() async throws {
        let device = try makeDevice()
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: device) else {
            throw XCTSkip("MTLIO requires a Metal 3 device outside the simulator")
        }
        let tile = Tile(x: 11, y: 12, z: 12)
        let preparedTile = makeRichPreparedTile(tile: tile)
        let cacheIdentity = makeCacheIdentity()

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobTransport: .file)
        let hit = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: URL(fileURLWithPath: "/nonexistent/gone.ptgeo"))

        let factory = MetalTileFactory(metalDevice: device)
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .imageUnreadable = result else {
            return XCTFail("A missing container must be reported unreadable, got \(result)")
        }
    }

    private func makeCacheIdentity() -> PreparedTileCacheIdentity {
        PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                  styleRevision: 1,
                                  tileSourceRevision: 2,
                                  flatSeparateRoadRenderingMinimumZoom: 3,
                                  textRevision: 4,
                                  labelLanguage: .english,
                                  labelFallbackPolicy: .international,
                                  houseNumbersEnabled: true,
                                  houseNumbersMinimumZoom: 15,
                                  capitalMaximumZoom: 12,
                                  cityMaximumZoom: 12,
                                  smallSettlementMaximumZoom: 12,
                                  landmarkMinimumZoom: 13,
                                  addTestBorders: false)
    }
}
