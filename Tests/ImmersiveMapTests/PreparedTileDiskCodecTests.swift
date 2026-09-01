// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class PreparedTileDiskCodecTests: XCTestCase {
    private static let testBlobURL = URL(fileURLWithPath: "/nonexistent/test.ptgeo")

    func testPreparedTileCacheFormatVersionIncludesArenaImageRevision() {
        XCTAssertEqual(PreparedTileDiskCaching.preparedFormatVersion, 79)
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

        let uncompressedData = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                                cacheIdentity: cacheIdentity,
                                                                compressionEnabled: false).metadata
        let encodedData = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                           cacheIdentity: cacheIdentity).metadata

        XCTAssertTrue(PreparedTileDiskEnvelope.isEnvelope(encodedData))
#if canImport(Compression)
        XCTAssertTrue(PreparedTileDiskEnvelope.isCompressedEnvelope(encodedData))
        XCTAssertLessThan(encodedData.count, uncompressedData.count)
#endif
        let decoded = try PreparedTileDiskCodec.decode(data: encodedData,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: Self.testBlobURL)
        XCTAssertEqual(decoded.image.tile, tile)
        assertTextLabelSetMeta(decoded.image.textLabelsFull, equals: preparedTile.textLabels.full)
        assertTextLabelSetMeta(decoded.image.textLabelsReduced, equals: preparedTile.textLabels.reduced)
        assertTextLabelSetMeta(decoded.image.textLabelsMinimal, equals: preparedTile.textLabels.minimal)
        XCTAssertEqual(inlineBlob(of: decoded.image),
                       makeBlobData(for: preparedTile),
                       "The inline blob must byte-match the arena plan of the encoded tile")
        XCTAssertEqual(decoded.image.spans,
                       TileArenaImageMath.plan(for: preparedTile).spans,
                       "The stored span table must match the plan the factory would build")
    }

    func testPreparedTileCodecFileTransportSeparatesBlobFromMetadata() throws {
        let tile = Tile(x: 3, y: 4, z: 5)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let preparedTile = makePreparedTile(
            tile: tile,
            textLabels: PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 7),
                                                    reduced: makeTextLabelSet(seed: 8),
                                                    minimal: makeTextLabelSet(seed: 9))
        )

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobTransport: .file(.raw))

        let fileBlob = try XCTUnwrap(encoded.fileBlob)
        XCTAssertEqual(fileBlob, makeBlobData(for: preparedTile),
                       "The file blob must be the same arena image the inline transport embeds")

        let decoded = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: Self.testBlobURL)
        guard case .file(let url, let format, let checksum) = decoded.image.blob else {
            return XCTFail("A file-transport entry must resolve to a file blob")
        }
        XCTAssertEqual(url, Self.testBlobURL)
        XCTAssertEqual(format, .raw)
        XCTAssertEqual(checksum, PreparedTileBlobChecksum.checksum(fileBlob),
                       "The stored checksum must cover the file blob bytes")
        XCTAssertEqual(decoded.image.arenaByteCount, fileBlob.count)
    }

    func testPreparedTileCodecRejectsTamperedSpanTable() throws {
        let tile = Tile(x: 6, y: 7, z: 8)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let preparedTile = makePreparedTile(
            tile: tile,
            textLabels: PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 1),
                                                    reduced: makeTextLabelSet(seed: 2),
                                                    minimal: makeTextLabelSet(seed: 3))
        )
        // A plist-level forgery: re-encode the entry with a truncated span
        // table but the original blob, which the structural validation must
        // reject before any span is trusted.
        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       compressionEnabled: false).metadata
        let payload = try PreparedTileDiskEnvelope.decode(data: encoded)
        guard var entry = try PropertyListSerialization.propertyList(from: payload,
                                                                     options: [],
                                                                     format: nil) as? [String: Any],
              var spanTable = entry["spanTable"] as? [[String: Any]],
              let removedIndex = spanTable.firstIndex(where: { ($0["byteCount"] as? Int ?? 0) > 0 }) else {
            return XCTFail("The v30 entry must carry a span table with a non-empty span")
        }
        // Removing an empty span keeps the offset chain intact (it occupies
        // no bytes); only dropping a non-empty span provably breaks it.
        spanTable.remove(at: removedIndex)
        entry["spanTable"] = spanTable
        let forgedPayload = try PropertyListSerialization.data(fromPropertyList: entry,
                                                               format: .binary,
                                                               options: 0)
        let forged = try PreparedTileDiskEnvelope.encode(payload: forgedPayload)

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: forged,
                                             expectedTile: tile,
                                             cacheIdentity: cacheIdentity,
                                             blobFileURL: Self.testBlobURL)
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    func testPreparedTileCodecRejectsCorruptedCompressedEnvelope() throws {
        let tile = Tile(x: 7, y: 8, z: 9)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        var data = try PreparedTileDiskCodec.encode(preparedTile: makePreparedTile(tile: tile),
                                                    cacheIdentity: cacheIdentity).metadata
        let lastIndex = data.index(before: data.endIndex)
        data[lastIndex] ^= 0xff

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: cacheIdentity,
                                             blobFileURL: Self.testBlobURL)
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

    func testPreparedTileEnvelopeDecodesVersionOneByteChecksummedEnvelope() throws {
        // Version-1 envelopes on disk carry a byte-wise FNV-1a checksum; newer
        // builds must keep reading them without invalidating the cache.
        let payload = Data((0..<100).map { UInt8($0 % 251) })
        var data = Data([0x49, 0x4d, 0x50, 0x54, 0x49, 0x4c, 0x45, 0x00])
        data.append(contentsOf: [0x01, 0x00]) // envelope version 1
        data.append(0x00) // uncompressed
        data.append(0x00) // reserved flags
        appendLittleEndian(UInt64(payload.count), to: &data)
        var byteChecksum: UInt64 = 14_695_981_039_346_656_037
        for byte in payload {
            byteChecksum ^= UInt64(byte)
            byteChecksum &*= 1_099_511_628_211
        }
        appendLittleEndian(byteChecksum, to: &data)
        data.append(payload)

        XCTAssertEqual(try PreparedTileDiskEnvelope.decode(data: data), payload)
    }

    func testPreparedTileEnvelopeWritesVersionTwo() throws {
        let encoded = try PreparedTileDiskEnvelope.encode(payload: Data([0x01, 0x02, 0x03]))

        XCTAssertEqual(encoded[8], 0x02)
        XCTAssertEqual(encoded[9], 0x00)
    }

    func testPreparedTileEnvelopeMatchesVersionTwoChecksumFixture() throws {
        // Golden version-2 envelope with an independently computed word-wise
        // checksum (little-endian 8-byte words, zero-padded tail). The
        // 11-byte payload exercises one full word plus a 3-byte tail, so the
        // constant pins byte order and tail padding: a mirrored mistake shared
        // by encode and decode survives the round-trip tests above but fails
        // against these fixed bytes.
        let payload = Data([0xa5, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0xff])
        var fixture = Data([0x49, 0x4d, 0x50, 0x54, 0x49, 0x4c, 0x45, 0x00])
        fixture.append(contentsOf: [0x02, 0x00]) // envelope version 2
        fixture.append(0x00) // uncompressed
        fixture.append(0x00) // reserved flags
        appendLittleEndian(UInt64(payload.count), to: &fixture)
        appendLittleEndian(UInt64(16_975_706_397_689_694_488), to: &fixture)
        fixture.append(payload)

        XCTAssertEqual(try PreparedTileDiskEnvelope.decode(data: fixture), payload)
        XCTAssertEqual(try PreparedTileDiskEnvelope.encode(payload: payload,
                                                           compressionEnabled: false),
                       fixture)
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

    func testPreparedTileEnvelopeSkipsCompressionWhenDisabled() throws {
        let payload = Data(repeating: 0, count: 1 * 1_024 * 1_024)

        let encoded = try PreparedTileDiskEnvelope.encode(payload: payload, compressionEnabled: false)

        XCTAssertTrue(PreparedTileDiskEnvelope.isEnvelope(encoded))
        XCTAssertFalse(PreparedTileDiskEnvelope.isCompressedEnvelope(encoded))
        XCTAssertEqual(try PreparedTileDiskEnvelope.decode(data: encoded), payload)
    }

    func testPreparedTileCodecRoundTripsWithCompressionDisabled() throws {
        let tile = Tile(x: 21, y: 22, z: 10)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let preparedTile = makePreparedTile(
            tile: tile,
            textLabels: PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 4),
                                                    reduced: makeTextLabelSet(seed: 5),
                                                    minimal: makeTextLabelSet(seed: 6))
        )

        let encodedData = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                           cacheIdentity: cacheIdentity,
                                                           compressionEnabled: false).metadata

        XCTAssertTrue(PreparedTileDiskEnvelope.isEnvelope(encodedData))
        XCTAssertFalse(PreparedTileDiskEnvelope.isCompressedEnvelope(encodedData))
        let decoded = try PreparedTileDiskCodec.decode(data: encodedData,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: Self.testBlobURL)
        XCTAssertEqual(decoded.image.tile, tile)
        assertTextLabelSetMeta(decoded.image.textLabelsFull, equals: preparedTile.textLabels.full)
        XCTAssertEqual(inlineBlob(of: decoded.image), makeBlobData(for: preparedTile))
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

        XCTAssertEqual(loaded?.image.tile, tile)
        let storedData = try Data(contentsOf: cache.cachePathFor(tile: tile))
        XCTAssertTrue(PreparedTileDiskEnvelope.isEnvelope(storedData))
    }

    func testPreparedTileDiskCacheWritesAndRemovesBlobPairWithFileTransport() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PreparedTileDiskCache-pair-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let tile = Tile(x: 14, y: 15, z: 13)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let config = ImmersiveMapSettings.default
            .tileSettings(preparedDiskCacheSizeInBytes: 4 * 1_024 * 1_024)
        let cache = PreparedTileDiskCaching(config: config,
                                            cacheIdentity: cacheIdentity,
                                            geometryTransport: PlainFileGeometryTransport(),
                                            baseCachesDirectory: baseDirectory)

        await cache.saveOnDisk(tile: tile,
                               preparedTile: makePreparedTile(
                                   tile: tile,
                                   textLabels: PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 1),
                                                                          reduced: makeTextLabelSet(seed: 2),
                                                                          minimal: makeTextLabelSet(seed: 3))),
                               sourceETag: "pair-etag")

        XCTAssertTrue(fileManager.fileExists(atPath: cache.cachePathFor(tile: tile).path))
        XCTAssertTrue(fileManager.fileExists(atPath: cache.blobPathFor(tile: tile).path),
                      "The file transport must write the sibling blob")

        let loaded = await cache.requestPreparedDiskCached(tile: tile, matchingETag: "pair-etag")
        guard case .file(let url, _, _) = loaded?.image.blob else {
            return XCTFail("A file-transport hit must reference the sibling blob")
        }
        XCTAssertEqual(url, cache.blobPathFor(tile: tile))

        cache.removeFromDisk(tile: tile)
        _ = await cache.requestPreparedDiskCached(tile: tile, matchingETag: nil)
        XCTAssertFalse(fileManager.fileExists(atPath: cache.cachePathFor(tile: tile).path))
        XCTAssertFalse(fileManager.fileExists(atPath: cache.blobPathFor(tile: tile).path),
                       "Removal must delete the metadata and the blob together")
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
                                                    cacheIdentity: cacheIdentity).metadata
        let decoded = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: Self.testBlobURL)

        XCTAssertEqual(decoded.image.tile, tile)
    }

    func testPreparedTileCodecRoundTripsTextLabelDetailTiers() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .portuguese)
        let textLabels = PreparedTileCPU.TextLabels(full: makeTextLabelSet(seed: 1),
                                                    reduced: makeTextLabelSet(seed: 2),
                                                    minimal: makeTextLabelSet(seed: 3))
        let preparedTile = makePreparedTile(tile: tile, textLabels: textLabels)

        let data = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                    cacheIdentity: cacheIdentity).metadata
        let decoded = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: Self.testBlobURL)

        assertTextLabelSetMeta(decoded.image.textLabelsFull, equals: textLabels.full)
        assertTextLabelSetMeta(decoded.image.textLabelsReduced, equals: textLabels.reduced)
        assertTextLabelSetMeta(decoded.image.textLabelsMinimal, equals: textLabels.minimal)
        XCTAssertEqual(inlineBlob(of: decoded.image), makeBlobData(for: preparedTile),
                       "Glyph and icon vertex bytes travel in the blob")
    }

    func testPreparedTileCodecRejectsMismatchedLabelLanguageMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese)
        ).metadata

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .english),
                                             blobFileURL: Self.testBlobURL)
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
        ).metadata

        // Matching ETag -> reused without re-parsing.
        let matched = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       expectedSourceETag: "etag-A",
                                                       blobFileURL: Self.testBlobURL)
        XCTAssertEqual(matched.image.tile, tile)

        // Different ETag (server content changed at the same URL) -> rejected.
        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: cacheIdentity,
                                             expectedSourceETag: "etag-B",
                                             blobFileURL: Self.testBlobURL)
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }

        // nil expected ETag (offline fallback) -> accepted regardless of stored ETag.
        let anyETag = try PreparedTileDiskCodec.decode(data: data,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       expectedSourceETag: nil,
                                                       blobFileURL: Self.testBlobURL)
        XCTAssertEqual(anyETag.image.tile, tile)
    }

    func testPreparedTileCodecRejectsMismatchedTextRevisionMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese, textRevision: 5)
        ).metadata

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese,
                                                                              textRevision: 6),
                                             blobFileURL: Self.testBlobURL)
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    func testPreparedTileCodecRejectsMismatchedLabelFallbackPolicyMetadata() throws {
        let tile = Tile(x: 1, y: 2, z: 3)
        let data = try PreparedTileDiskCodec.encode(
            preparedTile: makePreparedTile(tile: tile),
            cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese, fallbackPolicy: .international)
        ).metadata

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: data,
                                             expectedTile: tile,
                                             cacheIdentity: makeCacheIdentity(labelLanguage: .portuguese,
                                                                              fallbackPolicy: .localFirst),
                                             blobFileURL: Self.testBlobURL)
        ) { error in
            XCTAssertTrue(error is PreparedTileDiskCodecError)
        }
    }

    /// Layout oracle independent of the code under test: every expected
    /// offset and byte below is written out by hand from the format rules
    /// (schema order, 256-byte alignment, 16-bit narrowing, little-endian
    /// element layouts), not computed through plan/writeBlob, so a mirrored
    /// mistake shared by the writer and the reader cannot satisfy it.
    func testArenaBlobLayoutMatchesHandComputedBytes() throws {
        let tile = Tile(x: 2, y: 3, z: 7)
        let preparedTile = PreparedTileCPUTestFixtures.withGroundTriangle(tile: tile)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       compressionEnabled: false)
        let decoded = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: Self.testBlobURL)
        let blob = try XCTUnwrap(inlineBlob(of: decoded.image))
        let spans = decoded.image.spans

        // The vertex layout is a binding contract (vertex descriptor, arena
        // strides); pin the ABI before trusting stride-derived expectations.
        XCTAssertEqual(MemoryLayout<TileVertexIn>.stride, 8)

        // Slot sequence: 5 ground + 20 road phases x 5 (four structures:
        // tunnel, ground, automobile ground, bridge) + 5 bridge overlay
        // + 3 extruded + 0 label runs (all sets empty) + 1 road glyphs.
        XCTAssertEqual(spans.count, 114)

        // Ground vertices: 3 elements at offset 0, 24 bytes. The three
        // vertices are (0,0), (4096,0), (0,4096) with styleIndex 0, a zero
        // line distance and the saturated line parameter (0x7FFF little-endian
        // [0xFF, 0x7F]); 4096 is 0x1000, little-endian [0x00, 0x10].
        XCTAssertEqual(spans[0], TileArenaSpan(byteOffset: 0, byteCount: 24, elementCount: 3, indexWidth: nil))
        XCTAssertEqual(blob[0..<24], Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x7F,
                                           0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x7F,
                                           0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0xFF, 0x7F]))

        // Ground indices: [0, 1, 2] narrowed to UInt16 (3 vertices are far
        // below the 65535-vertex ceiling), 6 bytes at the next 256 boundary.
        XCTAssertEqual(spans[1], TileArenaSpan(byteOffset: 256, byteCount: 6, elementCount: 3, indexWidth: .uint16))
        XCTAssertEqual(blob[256..<262], Data([0x00, 0x00, 0x01, 0x00, 0x02, 0x00]))

        // Ground styles: the one red style, byte-equal to the source value.
        let styleStride = MemoryLayout<TilePolygonStyle>.stride
        XCTAssertEqual(spans[2],
                       TileArenaSpan(byteOffset: 512, byteCount: styleStride, elementCount: 1, indexWidth: nil))
        var expectedStyleBytes = Data(count: styleStride)
        expectedStyleBytes.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: preparedTile.ground.styles[0], toByteOffset: 0, as: TilePolygonStyle.self)
        }
        XCTAssertEqual(blob[512..<(512 + styleStride)], expectedStyleBytes)

        // Ground overview masks: one Float zero.
        XCTAssertEqual(spans[3], TileArenaSpan(byteOffset: 768, byteCount: 4, elementCount: 1, indexWidth: nil))
        XCTAssertEqual(blob[768..<772], Data([0x00, 0x00, 0x00, 0x00]))

        // Ground line styles: one all-zero TileLineStyle (the fixture style
        // is a plain polygon).
        XCTAssertEqual(spans[4], TileArenaSpan(byteOffset: 1024, byteCount: 32, elementCount: 1, indexWidth: nil))
        XCTAssertEqual(blob[1024..<1056], Data(count: 32))

        // Everything after the ground layer is empty: zero-length spans do
        // not advance the cursor, so the arena ends at the width span's
        // 256-byte boundary and the padding between contents stays zeroed.
        for span in spans[5...] {
            XCTAssertEqual(span.byteOffset, 1280)
            XCTAssertEqual(span.byteCount, 0)
        }
        XCTAssertEqual(decoded.image.arenaByteCount, 1280)
        XCTAssertEqual(blob.count, 1280)
        XCTAssertEqual(blob[24..<256], Data(count: 232), "Span padding must be deterministic zeros")
        XCTAssertEqual(blob[262..<512], Data(count: 250), "Span padding must be deterministic zeros")
        XCTAssertEqual(blob[772..<1024], Data(count: 252), "Span padding must be deterministic zeros")
        XCTAssertEqual(blob[1056..<1280], Data(count: 224), "Span padding must be deterministic zeros")
    }

    func testWideIndexGeometrySkipsNarrowingAndRoundTrips() throws {
        let tile = Tile(x: 9, y: 9, z: 11)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        // One vertex above the narrowing ceiling forces the uint32 path: the
        // dense-city geometry the cache exists to speed up.
        let vertexCount = IndexStorageMath.maximumNarrowableVertexCount + 1
        let preparedTile = PreparedTileCPUTestFixtures.withGround(
            tile: tile,
            ground: PreparedTileCPU.GeometryLayer(
                vertices: Array(repeating: TileVertexIn(position: SIMD2<Int16>(0, 0), styleIndex: 0),
                                count: vertexCount),
                indices: [0, UInt32(vertexCount - 1), 12_345],
                styles: [TilePolygonStyle(color: SIMD4<Float>(0, 1, 0, 1))],
                overviewStyleMasks: [0]
            )
        )

        let encoded = try PreparedTileDiskCodec.encode(preparedTile: preparedTile,
                                                       cacheIdentity: cacheIdentity,
                                                       compressionEnabled: false)
        let decoded = try PreparedTileDiskCodec.decode(data: encoded.metadata,
                                                       expectedTile: tile,
                                                       cacheIdentity: cacheIdentity,
                                                       blobFileURL: Self.testBlobURL)

        let indexSpan = decoded.image.spans[1]
        XCTAssertEqual(indexSpan.indexWidth, .uint32,
                       "Geometry above the narrowing ceiling must keep 32-bit indices")
        XCTAssertEqual(indexSpan.elementCount, 3)
        XCTAssertEqual(indexSpan.byteCount, 12)

        // Hand-computed little-endian UInt32 bytes: 0, 65535 (0x0000FFFF),
        // 12345 (0x00003039); independent of the narrowing implementation.
        let blob = try XCTUnwrap(inlineBlob(of: decoded.image))
        let start = indexSpan.byteOffset
        XCTAssertEqual(blob[start..<(start + 12)],
                       Data([0x00, 0x00, 0x00, 0x00,
                             0xff, 0xff, 0x00, 0x00,
                             0x39, 0x30, 0x00, 0x00]))
    }

    /// Regression for a crash-loop: a forged span table claiming byte counts
    /// near Int.max used to pass every guard and then trap on arithmetic
    /// overflow inside validation, before the removal path could run. It must
    /// throw like any other corruption.
    func testForgedSpanTableNearIntMaxFailsInsteadOfTrapping() throws {
        let tile = Tile(x: 6, y: 7, z: 8)
        let cacheIdentity = makeCacheIdentity(labelLanguage: .english)
        let encoded = try PreparedTileDiskCodec.encode(preparedTile: makePreparedTile(tile: tile),
                                                       cacheIdentity: cacheIdentity,
                                                       compressionEnabled: false).metadata
        let payload = try PreparedTileDiskEnvelope.decode(data: encoded)
        guard var entry = try PropertyListSerialization.propertyList(from: payload,
                                                                     options: [],
                                                                     format: nil) as? [String: Any] else {
            return XCTFail("The entry must decode as a property-list dictionary")
        }
        entry["arenaByteCount"] = Int.max
        entry["spanTable"] = [["byteOffset": 0, "byteCount": Int.max, "elementCount": 1]]
        let forgedPayload = try PropertyListSerialization.data(fromPropertyList: entry,
                                                               format: .binary,
                                                               options: 0)
        let forged = try PreparedTileDiskEnvelope.encode(payload: forgedPayload)

        XCTAssertThrowsError(
            try PreparedTileDiskCodec.decode(data: forged,
                                             expectedTile: tile,
                                             cacheIdentity: cacheIdentity,
                                             blobFileURL: Self.testBlobURL)
        ) { error in
            guard let codecError = error as? PreparedTileDiskCodecError,
                  case .corruptedPayload = codecError else {
                return XCTFail("Expected a corrupted-payload error, got \(error).")
            }
        }
    }

    // MARK: - Helpers

    /// File transport stand-in that writes the raw blob bytes: cache-level
    /// pair semantics (sibling write, paired removal) are testable without an
    /// MTLIO container, which only the render-side transport can produce.
    private struct PlainFileGeometryTransport: PreparedTileGeometryTransporting {
        let cacheNamespaceMarker = "btest"
        let blobTransport = PreparedTileGeometryBlobTransport.file(.raw)

        func stageBlobFile(_ blob: Data, near url: URL) throws -> URL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let stagedURL = makeStagingURL(near: url)
            try blob.write(to: stagedURL)
            return stagedURL
        }

        func commitStagedBlobFile(at stagedURL: URL, to url: URL) throws {
            try replaceFile(at: url, withStagedFileAt: stagedURL)
        }
    }

    private func makeBlobData(for preparedTile: PreparedTileCPU) -> Data {
        let plan = TileArenaImageMath.plan(for: preparedTile)
        var blob = Data(count: plan.totalByteCount)
        if plan.totalByteCount > 0 {
            blob.withUnsafeMutableBytes { bytes in
                TileArenaImageMath.writeBlob(plan: plan, into: bytes.baseAddress!)
            }
        }
        return blob
    }

    private func inlineBlob(of image: PreparedTileArenaImage) -> Data? {
        guard case .inline(let blob) = image.blob else {
            return nil
        }
        return blob
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
        let base = PreparedTileCPUTestFixtures.empty(tile: tile)
        guard let textLabels else {
            return base
        }
        return PreparedTileCPU(tile: tile,
                               ground: base.ground,
                               roads: base.roads,
                               bridgeOverlay: base.bridgeOverlay,
                               extruded: base.extruded,
                               textLabels: textLabels,
                               roadLabels: base.roadLabels)
    }

    private func makeTextLabelSet(seed: Int32) -> PreparedTileCPU.TextLabelSet {
        let placementInput = TextLabelPlacementInput(
            pointInput: TilePointInput(uv: SIMD2<Float>(Float(seed) + 0.1, Float(seed) + 0.2),
                                       tile: SIMD3<Int32>(seed, seed + 1, seed + 2),
                                       tileSlotIndex: UInt32(seed + 10)),
            placementMeta: LabelPlacementMeta(key: UInt64(seed + 100),
                                              sortKey: Int(seed + 200),
                                              collisionPriority: Int(seed + 300),
                                              labelSizePoints: SIMD2<Float>(Float(seed) + 10.1, Float(seed) + 20.2),
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
                       haloEm: Float(seed) + 1.5,
                       sizePoints: Float(seed) + 12.5,
                       weight: seed.isMultiple(of: 2) ? .thin : .bold)
    }

    private func makeLabelVertex(seed: Int32, labelIndex: Int32, spriteSeed: Int32) -> LabelVertex {
        LabelVertex(position: SIMD2<Float>(Float(seed) + 1.1, Float(seed) + 1.2),
                    uv: SIMD2<Float>(Float(seed) + 2.1, Float(seed) + 2.2),
                    labelIndex: labelIndex,
                    spriteUV: SIMD2<Float>(Float(spriteSeed) + 3.1, Float(spriteSeed) + 3.2))
    }

    private func assertTextLabelSetMeta(_ actual: PreparedTileArenaImage.TextLabelSetMeta,
                                        equals expected: PreparedTileCPU.TextLabelSet,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertEqual(actual.placementInputs.count, expected.placementInputs.count, file: file, line: line)
        XCTAssertEqual(actual.glyphRunStyles.count, expected.glyphRuns.count, file: file, line: line)
        XCTAssertEqual(actual.poiIconRunStyles.count, expected.poiIconRuns.count, file: file, line: line)
        guard actual.placementInputs.isEmpty == false,
              actual.glyphRunStyles.isEmpty == false,
              actual.poiIconRunStyles.isEmpty == false else {
            return
        }

        assertPlacementInput(actual.placementInputs[0], equals: expected.placementInputs[0], file: file, line: line)
        assertLabelTextStyle(actual.glyphRunStyles[0], equals: expected.glyphRuns[0].style, file: file, line: line)
        assertLabelTextStyle(actual.poiIconRunStyles[0],
                             equals: expected.poiIconRuns[0].style,
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
        XCTAssertEqual(actual.placementMeta.labelSizePoints, expected.placementMeta.labelSizePoints, file: file, line: line)
        XCTAssertEqual(actual.placementMeta.minCameraZoom, expected.placementMeta.minCameraZoom, file: file, line: line)
    }

    private func assertLabelTextStyle(_ actual: LabelTextStyle,
                                      equals expected: LabelTextStyle,
                                      file: StaticString,
                                      line: UInt) {
        XCTAssertEqual(actual.key, expected.key, file: file, line: line)
        XCTAssertEqual(actual.fillColor, expected.fillColor, file: file, line: line)
        XCTAssertEqual(actual.strokeColor, expected.strokeColor, file: file, line: line)
        XCTAssertEqual(actual.haloEm, expected.haloEm, file: file, line: line)
        XCTAssertEqual(actual.sizePoints, expected.sizePoints, file: file, line: line)
        XCTAssertEqual(actual.weight, expected.weight, file: file, line: line)
    }
}
