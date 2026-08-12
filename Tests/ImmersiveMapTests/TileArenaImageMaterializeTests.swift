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
            vertices: (0..<7).map { TileVertexIn(position: SIMD2<Int16>(Int16($0), Int16($0 * 2)), styleIndex: 0) },
            indices: [0, 1, 2, 2, 3, 4, 4, 5, 6],
            styles: [TilePolygonStyle(color: SIMD4<Float>(0.2, 0.4, 0.6, 1))],
            overviewStyleMasks: [1]
        )
        let roadFill = PreparedTileCPU.GeometryLayer(
            vertices: (0..<4).map { TileVertexIn(position: SIMD2<Int16>(Int16($0 * 3), 9), styleIndex: 0) },
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
                                                       blobTransport: .file(.lzfseContainer))
        let fileBlob = try XCTUnwrap(encoded.fileBlob)
        let transport = MTLIOPreparedTileGeometryTransport(compressionEnabled: true)
        let stagedURL = try transport.stageBlobFile(fileBlob, near: blobURL)
        try transport.commitStagedBlobFile(at: stagedURL, to: blobURL)

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

        XCTAssertEqual(try arenaBytes(of: materialized), fileBlob,
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
                                                       blobTransport: .file(.lzfseContainer))
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

    func testMTLIOTransportFormatFollowsCompressionSetting() {
        XCTAssertEqual(MTLIOPreparedTileGeometryTransport(compressionEnabled: true).blobTransport,
                       .file(.lzfseContainer))
        XCTAssertEqual(MTLIOPreparedTileGeometryTransport(compressionEnabled: false).blobTransport,
                       .file(.raw),
                       "preparedDiskCompressionEnabled must reach the bytes that dominate the entry")
    }

    func testRawContainerRoundTripsWhenCompressionDisabled() async throws {
        let device = try makeDevice()
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: device) else {
            throw XCTSkip("MTLIO requires a Metal 3 device outside the simulator")
        }
        guard device.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct buffer readback")
        }
        let tile = Tile(x: 13, y: 14, z: 12)
        let preparedTile = makeRichPreparedTile(tile: tile)
        let cacheIdentity = makeCacheIdentity()

        let blobURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileArenaImage-raw-\(UUID().uuidString).ptgeo")
        defer { try? FileManager.default.removeItem(at: blobURL) }

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobTransport: .file(.raw))
        let fileBlob = try XCTUnwrap(encoded.fileBlob)
        let transport = MTLIOPreparedTileGeometryTransport(compressionEnabled: false)
        let stagedURL = try transport.stageBlobFile(fileBlob, near: blobURL)
        try transport.commitStagedBlobFile(at: stagedURL, to: blobURL)

        XCTAssertEqual(try Data(contentsOf: blobURL), fileBlob,
                       "With compression disabled the container is the raw arena bytes")

        let hit = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: blobURL)
        let factory = MetalTileFactory(metalDevice: device)
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .tile(let materialized) = result else {
            return XCTFail("The raw MTLIO load must materialize, got \(result)")
        }
        XCTAssertEqual(try arenaBytes(of: materialized), fileBlob)
    }

    /// The torn-pair scenario: metadata from one save next to the container
    /// of another (a crash between the pair's two writes, or a second engine
    /// on the same namespace). The MTLIO load itself completes; only the
    /// checksum stored in the metadata can tell, and it must fail the
    /// materialize into removal instead of serving foreign bytes.
    func testTornMetadataContainerPairFailsAsUnreadable() async throws {
        let device = try makeDevice()
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: device) else {
            throw XCTSkip("MTLIO requires a Metal 3 device outside the simulator")
        }
        let tile = Tile(x: 15, y: 16, z: 12)
        let cacheIdentity = makeCacheIdentity()
        let originalTile = makeRichPreparedTile(tile: tile)
        // Same structure, different content: the sizes match, so nothing but
        // the checksum distinguishes the pair.
        var replacementGround = makeRichPreparedTile(tile: tile)
        replacementGround = PreparedTileCPU(
            tile: tile,
            ground: PreparedTileCPU.GeometryLayer(
                vertices: replacementGround.ground.vertices.map { _ in
                    TileVertexIn(position: SIMD2<Int16>(31, 41), styleIndex: 0)
                },
                indices: replacementGround.ground.indices,
                styles: replacementGround.ground.styles,
                overviewStyleMasks: replacementGround.ground.overviewStyleMasks
            ),
            roads: replacementGround.roads,
            bridgeOverlay: replacementGround.bridgeOverlay,
            extruded: replacementGround.extruded,
            textLabels: replacementGround.textLabels,
            roadLabels: replacementGround.roadLabels
        )

        let blobURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileArenaImage-torn-\(UUID().uuidString).ptgeo")
        defer { try? FileManager.default.removeItem(at: blobURL) }

        let originalEncoded = try PreparedTileDiskCodec.encode(preparedTile: originalTile,
                                                               cacheIdentity: cacheIdentity,
                                                               blobTransport: .file(.lzfseContainer))
        let replacementEncoded = try PreparedTileDiskCodec.encode(preparedTile: replacementGround,
                                                                  cacheIdentity: cacheIdentity,
                                                                  blobTransport: .file(.lzfseContainer))
        XCTAssertEqual(originalEncoded.fileBlob?.count, replacementEncoded.fileBlob?.count,
                       "The torn pair must not be distinguishable by size alone")

        // The container on disk is the replacement's; the metadata is the
        // original's.
        let transport = MTLIOPreparedTileGeometryTransport(compressionEnabled: true)
        let stagedURL = try transport.stageBlobFile(try XCTUnwrap(replacementEncoded.fileBlob), near: blobURL)
        try transport.commitStagedBlobFile(at: stagedURL, to: blobURL)

        let hit = try PreparedTileDiskCodec.decode(data: originalEncoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: blobURL)
        let factory = MetalTileFactory(metalDevice: device)
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .imageUnreadable = result else {
            return XCTFail("A torn pair must be reported unreadable, got \(result)")
        }
    }

    /// Single-bit corruption inside the container: the DMA load reports
    /// complete and delivers the flipped byte, so only the checksum
    /// comparison catches it.
    ///
    /// Deliberately a raw container: the checksum catch under test is
    /// format-independent, and feeding the hardware LZFSE decompressor a
    /// corrupted chunk stream wedges the IOGPU driver when the process has
    /// prior MTLIO traffic (empirical on macOS 15 / Apple M2: the load never
    /// completes and the awaiting test hangs the whole suite). Corrupt
    /// content therefore goes through the raw path here; compressed-path
    /// coverage uses valid streams only.
    func testBitFlippedContainerFailsAsUnreadable() async throws {
        let device = try makeDevice()
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: device) else {
            throw XCTSkip("MTLIO requires a Metal 3 device outside the simulator")
        }
        let tile = Tile(x: 17, y: 18, z: 12)
        let preparedTile = makeRichPreparedTile(tile: tile)
        let cacheIdentity = makeCacheIdentity()

        let blobURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileArenaImage-flip-\(UUID().uuidString).ptgeo")
        defer { try? FileManager.default.removeItem(at: blobURL) }

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobTransport: .file(.raw))
        let transport = MTLIOPreparedTileGeometryTransport(compressionEnabled: false)
        let stagedURL = try transport.stageBlobFile(try XCTUnwrap(encoded.fileBlob), near: blobURL)
        try transport.commitStagedBlobFile(at: stagedURL, to: blobURL)

        var containerBytes = try Data(contentsOf: blobURL)
        containerBytes[containerBytes.count / 2] ^= 0x40
        try containerBytes.write(to: blobURL)

        let hit = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: blobURL)
        let factory = MetalTileFactory(metalDevice: device)
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .imageUnreadable = result else {
            return XCTFail("A bit-flipped container must be reported unreadable, got \(result)")
        }
    }

    /// A truncated container (torn write, disk-full): the load can still
    /// complete with a short or zero-filled tail, and the checksum must
    /// reject it. Raw for the same driver-safety reason as the bit-flip
    /// test above.
    func testTruncatedContainerFailsAsUnreadable() async throws {
        let device = try makeDevice()
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: device) else {
            throw XCTSkip("MTLIO requires a Metal 3 device outside the simulator")
        }
        let tile = Tile(x: 19, y: 20, z: 12)
        let preparedTile = makeRichPreparedTile(tile: tile)
        let cacheIdentity = makeCacheIdentity()

        let blobURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileArenaImage-trunc-\(UUID().uuidString).ptgeo")
        defer { try? FileManager.default.removeItem(at: blobURL) }

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobTransport: .file(.raw))
        let transport = MTLIOPreparedTileGeometryTransport(compressionEnabled: false)
        let stagedURL = try transport.stageBlobFile(try XCTUnwrap(encoded.fileBlob), near: blobURL)
        try transport.commitStagedBlobFile(at: stagedURL, to: blobURL)

        var containerBytes = try Data(contentsOf: blobURL)
        containerBytes.removeLast(min(300, containerBytes.count / 2))
        try containerBytes.write(to: blobURL)

        let hit = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: blobURL)
        let factory = MetalTileFactory(metalDevice: device)
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .imageUnreadable = result else {
            return XCTFail("A truncated container must be reported unreadable, got \(result)")
        }
    }

    /// The uint32 index path through the real factory: geometry above the
    /// narrowing ceiling must materialize identically from a parse and from
    /// a decoded image, with 32-bit index views on both.
    func testWideIndexGeometryMaterializesIdenticallyFromImage() async throws {
        let device = try makeDevice()
        guard device.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct buffer readback")
        }
        let tile = Tile(x: 21, y: 22, z: 12)
        let vertexCount = IndexStorageMath.maximumNarrowableVertexCount + 1
        let preparedTile = PreparedTileCPUTestFixtures.withGround(
            tile: tile,
            ground: PreparedTileCPU.GeometryLayer(
                vertices: (0..<vertexCount).map {
                    TileVertexIn(position: SIMD2<Int16>(Int16(truncatingIfNeeded: $0), 7), styleIndex: 0)
                },
                indices: [0, UInt32(vertexCount - 1), 65_534],
                styles: [TilePolygonStyle(color: SIMD4<Float>(1, 0, 1, 1))],
                overviewStyleMasks: [0]
            )
        )
        let cacheIdentity = makeCacheIdentity()

        let factory = MetalTileFactory(metalDevice: device)
        let parsed = try XCTUnwrap(factory.makeTile(from: preparedTile))
        XCTAssertEqual(parsed.tileBuffers.ground.indexType, .uint32,
                       "Geometry above the narrowing ceiling must keep 32-bit indices")

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity)
        let hit = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                   expectedTile: tile,
                                                   cacheIdentity: cacheIdentity,
                                                   blobFileURL: URL(fileURLWithPath: "/nonexistent"))
        let result = await factory.makeTile(fromImage: hit.image)
        guard case .tile(let materialized) = result else {
            return XCTFail("The wide-index image must materialize, got \(result)")
        }
        XCTAssertEqual(materialized.tileBuffers.ground.indexType, .uint32)
        XCTAssertEqual(materialized.tileBuffers.ground.indicesCount, parsed.tileBuffers.ground.indicesCount)
        XCTAssertEqual(try arenaBytes(of: materialized), try arenaBytes(of: parsed))
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
