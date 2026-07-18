// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PreparedTileDiskCodecTests: XCTestCase {
    func testPreparedTileCacheFormatVersionIncludesLabelVisibilityPolicyRevision() {
        XCTAssertEqual(PreparedTileDiskCaching.preparedFormatVersion, 22)
    }

    func testPreparedTileCodecCompressesEnvelopeAndRoundTrips() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let preparedTile = makePreparedTile(
            tile: tile,
            textLabels: PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 1),
                                                    reduced: makeTextLabelSet(seed: 2),
                                                    minimal: makeTextLabelSet(seed: 3))
        )

        let legacyData = try PreparedTileDiskCodec.encodeLegacyPropertyList(
            preparedTile: preparedTile,
            cacheIdentity: cacheIdentity
        )
        let encodedData = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                           cacheIdentity: cacheIdentity)

        XCTAssertTrue(PreparedTileDiskEnvelope.isEnvelope(encodedData))
#if canImport(Compression)
        XCTAssertTrue(PreparedTileDiskEnvelope.isCompressedEnvelope(encodedData))
        XCTAssertLessThan(encodedData.count, legacyData.count)
#endif
        let decoded = try PreparedTileDiskCodec.decode(data: encodedData,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity)
        XCTAssertEqual(decoded.tile, tile)
        assertTextLabelSet(decoded.textLabels.full, equals: preparedTile.textLabels.full)
    }

    func testPreparedTileCodecReadsLegacyUncompressedPropertyList() throws {
        let tile = Tile(x: 4, y: 5, z: 6)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let legacyData = try PreparedTileDiskCodec.encodeLegacyPropertyList(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: cacheIdentity,
            sourceETag: "legacy-etag"
        )

        XCTAssertFalse(PreparedTileDiskEnvelope.isEnvelope(legacyData))
        let decoded = try PreparedTileDiskCodec.decode(data: legacyData,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       expectedSourceETag: "legacy-etag")
        XCTAssertEqual(decoded.tile, tile)
    }

    func testPreparedTileCodecRejectsCorruptedCompressedEnvelope() throws {
        let tile = Tile(x: 7, y: 8, z: 9)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        var data = try PreparedTileDiskCodec.encode(preparedTile: makePreparedTile(tile: tile),
                                                    cacheIdentity: cacheIdentity)
        let lastIndex = data.index(before: data.endIndex)
        data[lastIndex] ^= 0xff

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: cacheIdentity)
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    func testPreparedTileEnvelopeRejectsDecodedPayloadAbovePerTileLimit() {
        let data = makeCompressedEnvelope(
            decodedByteCount: UInt64(64 * 1_024 * 1_024 + 1),
            storedPayload: Data([0])
        )

        XCTAssertThrowsError(try PreparedTileDiskEnvelope.decode(data: data)) { error in
            guard let codecError = error as? PreparedTileDiskCodecError,
                  case let .corruptedPayload(message) = codecError else {
                return XCTFail("Expected a corrupted-payload error, got \(error).")
            }
            XCTAssertEqual(message, "Prepared-tile envelope is too large.")
        }
    }

    func testPreparedTileEnvelopeRejectsImplausibleCompressionExpansion() {
        let data = makeCompressedEnvelope(
            decodedByteCount: UInt64(1 * 1_024 * 1_024),
            storedPayload: Data(repeating: 0, count: 16)
        )

        XCTAssertThrowsError(try PreparedTileDiskEnvelope.decode(data: data)) { error in
            guard let codecError = error as? PreparedTileDiskCodecError,
                  case let .corruptedPayload(message) = codecError else {
                return XCTFail("Expected a corrupted-payload error, got \(error).")
            }
            XCTAssertEqual(message, "Prepared-tile envelope has an implausible compression ratio.")
        }
    }

    func testPreparedTileEnvelopeRejectsCompressedPayloadBelowMinimumStoredSize() {
        let data = makeCompressedEnvelope(
            decodedByteCount: UInt64(1),
            storedPayload: Data([0])
        )

        XCTAssertThrowsError(try PreparedTileDiskEnvelope.decode(data: data)) { error in
            guard let codecError = error as? PreparedTileDiskCodecError,
                  case let .corruptedPayload(message) = codecError else {
                return XCTFail("Expected a corrupted-payload error, got \(error).")
            }
            XCTAssertEqual(message, "Prepared-tile envelope has an implausible compression ratio.")
        }
    }

    func testPreparedTileEnvelopeRoundTripsHighlyCompressiblePayload() throws {
        let payload = Data(repeating: 0, count: 1 * 1_024 * 1_024)

        let encoded = try PreparedTileDiskEnvelope.encode(payload: payload)

        XCTAssertEqual(try PreparedTileDiskEnvelope.decode(data: encoded), payload)
    }

    func testPreparedTileEnvelopeFallsBackToRawPayloadWhenCompressionWouldGrowIt() throws {
        let payload = Data([0x7f])
        let encoded = try PreparedTileDiskEnvelope.encode(payload: payload)

        XCTAssertTrue(PreparedTileDiskEnvelope.isEnvelope(encoded))
        XCTAssertFalse(PreparedTileDiskEnvelope.isCompressedEnvelope(encoded))
        XCTAssertEqual(try PreparedTileDiskEnvelope.decode(data: encoded), payload)
    }

    func testPreparedTileDiskCacheSerializesSaveBeforeFollowingRead() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparedTileDiskCache-ordering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let tile = Tile(x: 11, y: 12, z: 13)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let config = ImmersiveMapSettings.default
            .tileSettings(preparedDiskCacheSizeInBytes: 4 * 1_024 * 1_024)
        let cache = PreparedTileDiskCaching(config: config,
                                            cacheIdentity: cacheIdentity,
                                            baseCachesDirectory: baseDirectory)

        await cache.saveOnDisk(tile: tile,
                               preparedTile: makePreparedTile(tile: tile),
                               sourceETag: "ordered-etag")
        let loaded = await cache.requestPreparedDiskCached(tile: tile, matchingETag: "ordered-etag")

        XCTAssertEqual(loaded?.tile, tile)
        let storedData = try Data(contentsOf: cache.cachePathFor(tile: tile))
        XCTAssertTrue(PreparedTileDiskEnvelope.isEnvelope(storedData))
    }

    func testPreparedTileDiskCachePrunesOldestFilesAcrossAllNamespaces() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PreparedTileDiskCache-quota-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let root = baseDirectory.appendingPathComponent("MapPreparedTiles")
        let oldest = root.appendingPathComponent("v18/old-style/old.ptile")
        let middle = root.appendingPathComponent("v19/other-style/middle.ptile")
        let newest = root.appendingPathComponent("v20/latest-style/new.ptile")
        let files = [oldest, middle, newest]
        for file in files {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try Data(repeating: 0xab, count: 10).write(to: file)
        }
        let now = Date()
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-300)],
                                      ofItemAtPath: oldest.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-200)],
                                      ofItemAtPath: middle.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-100)],
                                      ofItemAtPath: newest.path)

        let config = ImmersiveMapSettings.default
            .tileSettings(preparedDiskCacheSizeInBytes: 15)
        let cache = PreparedTileDiskCaching(config: config,
                                            cacheIdentity: makeCacheIdentity(labelLanguage: .english),
                                            baseCachesDirectory: baseDirectory)

        // A read submitted after init is a deterministic barrier for the async
        // root scan/prune; no sleeps or main-thread blocking are needed.
        _ = await cache.requestPreparedDiskCached(tile: Tile(x: 100, y: 100, z: 10),
                                                  matchingETag: nil)

        XCTAssertFalse(fileManager.fileExists(atPath: oldest.path))
        XCTAssertFalse(fileManager.fileExists(atPath: middle.path))
        XCTAssertTrue(fileManager.fileExists(atPath: newest.path))
    }

    func testPreparedTileDiskCacheExpiresFilesAcrossOldNamespaces() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PreparedTileDiskCache-ttl-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let root = baseDirectory.appendingPathComponent("MapPreparedTiles")
        let expired = root.appendingPathComponent("v17/obsolete-style/expired.ptile")
        let current = root.appendingPathComponent("v20/recent-style/current.ptile")
        for file in [expired, current] {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try Data(repeating: 0xcd, count: 10).write(to: file)
        }
        let now = Date()
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-120)],
                                      ofItemAtPath: expired.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-10)],
                                      ofItemAtPath: current.path)

        let config = ImmersiveMapSettings.default
            .tileSettings(preparedDiskTimeToLive: 60,
                          preparedDiskCacheSizeInBytes: 1_024)
        let cache = PreparedTileDiskCaching(config: config,
                                            cacheIdentity: makeCacheIdentity(labelLanguage: .english),
                                            baseCachesDirectory: baseDirectory)
        _ = await cache.requestPreparedDiskCached(tile: Tile(x: 101, y: 101, z: 10),
                                                  matchingETag: nil)

        XCTAssertFalse(fileManager.fileExists(atPath: expired.path))
        XCTAssertTrue(fileManager.fileExists(atPath: current.path))
    }

    func testPreparedTileCodecRoundTripsArbitraryLabelLanguageMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let labelLanguage = ImmersiveMapSettings.LabelLanguage("pt-BR")
        let cacheIdentity = makeCacheIdentity(labelLanguage: labelLanguage)
        let preparedTile = makePreparedTile(tile: tile)

        let data = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                    cacheIdentity: cacheIdentity)
        let decoded = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity)

        XCTAssertEqual(decoded.tile, tile)
    }

    func testPreparedTileCodecRoundTripsTextLabelDetailTiers() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .portuguese)
        let textLabels = PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 1),
                                                    reduced: makeTextLabelSet(seed: 2),
                                                    minimal: makeTextLabelSet(seed: 3))
        let preparedTile = makePreparedTile(tile: tile, textLabels: textLabels)

        let data = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                    cacheIdentity: cacheIdentity)
        let decoded = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity)

        assertTextLabelSet(decoded.textLabels.full, equals: textLabels.full)
        assertTextLabelSet(decoded.textLabels.reduced, equals: textLabels.reduced)
        assertTextLabelSet(decoded.textLabels.minimal, equals: textLabels.minimal)
    }

    func testPreparedTileCodecRejectsMismatchedLabelLanguageMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese)
        )

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .english))
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    func testPreparedTileCodecKeysOnSourceETag() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .portuguese)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: cacheIdentity,
            sourceETag: "etag-A"
        )

        // Matching ETag -> reused without re-parsing.
        let matched = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       expectedSourceETag: "etag-A")
        XCTAssertEqual(matched.tile, tile)

        // Different ETag (server content changed at the same URL) -> rejected.
        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: cacheIdentity,
                                             expectedSourceETag: "etag-B")
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }

        // nil expected ETag (offline fallback) -> accepted regardless of stored ETag.
        let anyETag = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       expectedSourceETag: nil)
        XCTAssertEqual(anyETag.tile, tile)
    }

    func testPreparedTileCodecRejectsMismatchedTextRevisionMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese, textRevision: 5)
        )

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese,
                                                                              textRevision: 6))
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    func testPreparedTileCodecRejectsMismatchedLabelFallbackPolicyMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese, fallbackPolicy: .international)
        )

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese,
                                                                              fallbackPolicy: .localFirst))
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    private func makeCompressedEnvelope(decodedByteCount: UInt64,
                                        storedPayload: Data) -> Data {
        var data = Data([0x49, 0x4d, 0x50, 0x54, 0x49, 0x4c, 0x45, 0x00])
        data.append(contentsOf: [0x01, 0x00]) // envelope version 1
        data.append(0x01) // LZFSE
        data.append(0x00) // reserved flags
        appendLittleEndian(decodedByteCount, to: &data)
        appendLittleEndian(UInt64(0), to: &data) // checksum is not reached by these validations
        data.append(storedPayload)
        return data
    }

    private func appendLittleEndian(_ value: UInt64, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func makeCacheIdentity(labelLanguage: ImmersiveMapSettings.LabelLanguage,
                                   fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy = .international,
                                   textRevision: UInt32 = 4) -> PreparedTileCacheIdentity {
        PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                  styleRevision: 1,
                                  tileSourceRevision: 2,
                                  flatSeparateRoadRenderingMinimumZoom: 3,
                                  textRevision: textRevision,
                                  labelLanguage: labelLanguage,
                                  labelFallbackPolicy: fallbackPolicy,
                                  houseNumbersEnabled: true,
                                  houseNumbersMinimumZoom: 15,
                                  capitalMaximumZoom: 12,
                                  cityMaximumZoom: 12,
                                  smallSettlementMaximumZoom: 12,
                                  landmarkMinimumZoom: 13,
                                  addTestBorders: false)
    }

    private func makePreparedTile(tile: Tile,
                                  textLabels: PreparedTileCPU.TextLabels? = nil) -> PreparedTileCPU {
        let emptyGeometry = PreparedTileCPU.GeometryLayer(vertices: [],
                                                         indices: [],
                                                         styles: [],
                                                         overviewStyleMasks: [])
        let emptyRoadPhases = RoadGeometryPhases(shadow: emptyGeometry,
                                                 casing: emptyGeometry,
                                                 fill: emptyGeometry,
                                                 detail: emptyGeometry,
                                                 overlay: emptyGeometry)

        return PreparedTileCPU(tile: tile,
                               ground: emptyGeometry,
                               roads: RoadStructureBuckets(tunnel: emptyRoadPhases,
                                                          ground: emptyRoadPhases,
                                                          bridge: emptyRoadPhases),
                               bridgeOverlay: emptyGeometry,
                               extruded: PreparedTileCPU.Extruded(vertices: [],
                                                                  indices: [],
                                                                  styles: []),
                               textLabels: textLabels ?? PreparedTileCPU.TextLabels(full: emptyTextLabelSet(),
                                                                                    reduced: emptyTextLabelSet(),
                                                                                    minimal: emptyTextLabelSet()),
                               roadLabels: PreparedTileCPU.RoadLabels(pathInputs: [],
                                                                      pathRanges: [],
                                                                      pathLabels: [],
                                                                      labelStyle: nil,
                                                                      localGlyphVertices: [],
                                                                      glyphBounds: [],
                                                                      glyphBoundRanges: [],
                                                                      sizes: [],
                                                                      anchorRanges: [],
                                                                      anchors: []))
    }

    private func emptyTextLabelSet() -> PreparedTileCPU.TextLabelSet {
        PreparedTileCPU.TextLabelSet(placementInputs: [],
                                     glyphRuns: [],
                                     poiIconRuns: [])
    }

    private func makeTextLabelSet(seed: Int32) -> PreparedTileCPU.TextLabelSet {
        let placementInput = TextLabelPlacementInput(
            pointInput: TilePointInput(uv: SIMD2<Float>(Float(seed) + 0.1, Float(seed) + 0.2),
                                       tile: SIMD3<Int32>(seed, seed + 1, seed + 2),
                                       tileSlotIndex: UInt32(seed + 10)),
            placementMeta: LabelPlacementMeta(key: UInt64(seed + 100),
                                              sortKey: Int(seed + 200),
                                              collisionPriority: Int(seed + 300),
                                              labelSizePx: SIMD2<Float>(Float(seed) + 10.1, Float(seed) + 20.2),
                                              minCameraZoom: Float(seed) + 0.5)
        )
        let glyphVertex = makeLabelVertex(seed: seed, labelIndex: seed + 400, spriteSeed: 0)
        let poiIconVertex = makeLabelVertex(seed: seed + 10, labelIndex: seed + 500, spriteSeed: seed + 20)

        return PreparedTileCPU.TextLabelSet(
            placementInputs: [placementInput],
            glyphRuns: [PreparedTileCPU.TextGlyphRun(style: makeLabelTextStyle(seed: seed),
                                                     localGlyphVertices: [glyphVertex])],
            poiIconRuns: [PreparedTileCPU.PoiIconRun(style: makeLabelTextStyle(seed: seed + 30),
                                                     localIconVertices: [poiIconVertex])]
        )
    }

    private func makeLabelTextStyle(seed: Int32) -> LabelTextStyle {
        LabelTextStyle(key: Int(seed + 600),
                       fillColor: SIMD3<Float>(Float(seed) + 0.01, Float(seed) + 0.02, Float(seed) + 0.03),
                       strokeColor: SIMD3<Float>(Float(seed) + 0.04, Float(seed) + 0.05, Float(seed) + 0.06),
                       strokeWidthPx: Float(seed) + 1.5,
                       sizePx: Float(seed) + 12.5,
                       weight: seed.isMultiple(of: 2) ? .thin : .bold)
    }

    private func makeLabelVertex(seed: Int32, labelIndex: Int32, spriteSeed: Int32) -> LabelVertex {
        LabelVertex(position: SIMD2<Float>(Float(seed) + 1.1, Float(seed) + 1.2),
                    uv: SIMD2<Float>(Float(seed) + 2.1, Float(seed) + 2.2),
                    labelIndex: labelIndex,
                    spriteUV: SIMD2<Float>(Float(spriteSeed) + 3.1, Float(spriteSeed) + 3.2))
    }

    private func assertTextLabelSet(_ actual: PreparedTileCPU.TextLabelSet,
                                    equals expected: PreparedTileCPU.TextLabelSet,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertEqual(actual.placementInputs.count, expected.placementInputs.count, file: file, line: line)
        XCTAssertEqual(actual.glyphRuns.count, expected.glyphRuns.count, file: file, line: line)
        XCTAssertEqual(actual.poiIconRuns.count, expected.poiIconRuns.count, file: file, line: line)
        guard actual.placementInputs.isEmpty == false,
              actual.glyphRuns.isEmpty == false,
              actual.poiIconRuns.isEmpty == false else {
            return
        }
        XCTAssertEqual(actual.glyphRuns[0].localGlyphVertices.count,
                       expected.glyphRuns[0].localGlyphVertices.count,
                       file: file,
                       line: line)
        XCTAssertEqual(actual.poiIconRuns[0].localIconVertices.count,
                       expected.poiIconRuns[0].localIconVertices.count,
                       file: file,
                       line: line)
        guard actual.glyphRuns[0].localGlyphVertices.isEmpty == false,
              actual.poiIconRuns[0].localIconVertices.isEmpty == false else {
            return
        }

        assertPlacementInput(actual.placementInputs[0], equals: expected.placementInputs[0], file: file, line: line)
        assertLabelTextStyle(actual.glyphRuns[0].style, equals: expected.glyphRuns[0].style, file: file, line: line)
        assertLabelVertex(actual.glyphRuns[0].localGlyphVertices[0],
                          equals: expected.glyphRuns[0].localGlyphVertices[0],
                          file: file,
                          line: line)
        assertLabelTextStyle(actual.poiIconRuns[0].style,
                             equals: expected.poiIconRuns[0].style,
                             file: file,
                             line: line)
        assertLabelVertex(actual.poiIconRuns[0].localIconVertices[0],
                          equals: expected.poiIconRuns[0].localIconVertices[0],
                          file: file,
                          line: line)
    }

    private func assertPlacementInput(_ actual: TextLabelPlacementInput,
                                      equals expected: TextLabelPlacementInput,
                                      file: StaticString,
                                      line: UInt) {
        XCTAssertEqual(actual.pointInput.uv, expected.pointInput.uv, file: file, line: line)
        XCTAssertEqual(actual.pointInput.tile, expected.pointInput.tile, file: file, line: line)
        XCTAssertEqual(actual.pointInput.tileSlotIndex, expected.pointInput.tileSlotIndex, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.key, expected.placementMeta.key, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.sortKey, expected.placementMeta.sortKey, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.collisionPriority,
                       expected.placementMeta.collisionPriority,
                       file: file,
                       line: line)
        XCTAssertEqual(actual.placementMeta.labelSizePx, expected.placementMeta.labelSizePx, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.minCameraZoom, expected.placementMeta.minCameraZoom, file: file, line: line)
    }

    private func assertLabelTextStyle(_ actual: LabelTextStyle,
                                      equals expected: LabelTextStyle,
                                      file: StaticString,
                                      line: UInt) {
        XCTAssertEqual(actual.key, expected.key, file: file, line: line)
        XCTAssertEqual(actual.fillColor, expected.fillColor, file: file, line: line)
        XCTAssertEqual(actual.strokeColor, expected.strokeColor, file: file, line: line)
        XCTAssertEqual(actual.strokeWidthPx, expected.strokeWidthPx, file: file, line: line)
        XCTAssertEqual(actual.sizePx, expected.sizePx, file: file, line: line)
        XCTAssertEqual(actual.weight, expected.weight, file: file, line: line)
    }

    private func assertLabelVertex(_ actual: LabelVertex,
                                   equals expected: LabelVertex,
                                   file: StaticString,
                                   line: UInt) {
        XCTAssertEqual(actual.position, expected.position, file: file, line: line)
        XCTAssertEqual(actual.uv, expected.uv, file: file, line: line)
        XCTAssertEqual(actual.labelIndex, expected.labelIndex, file: file, line: line)
        XCTAssertEqual(actual.spriteUV, expected.spriteUV, file: file, line: line)
    }
}
