// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd
#if canImport(Compression)
import Compression
#endif

enum PreparedTileDiskCodecError: Error {
    case invalidField(String)
    case invalidMetadata
    case corruptedPayload(String)
}

/// A small, independently versioned wrapper around the prepared-tile property
/// list. Keeping this version separate from `preparedFormatVersion` lets newer
/// builds read the unwrapped binary plists written by older builds while still
/// allowing the on-disk transport to evolve.
enum PreparedTileDiskEnvelope {
    private enum Algorithm: UInt8 {
        case uncompressed = 0
        case lzfse = 1
    }

    private static let magic = Data([0x49, 0x4d, 0x50, 0x54, 0x49, 0x4c, 0x45, 0x00]) // "IMPTILE\0"
    // Version 1 checksums the payload with byte-wise FNV-1a; version 2 hashes
    // 8-byte words instead, which verifies megabyte payloads an order of
    // magnitude faster. Both are readable; new envelopes are written as 2.
    private static let byteChecksumVersion: UInt16 = 1
    private static let currentVersion: UInt16 = 2
    private static let headerSize = 28
    // A prepared tile is a cache artifact for one source tile. 64 MiB leaves
    // ample room for dense geometry while bounding any single decode allocation.
    private static let maximumDecodedPayloadSize = 64 * 1_024 * 1_024
    // Real prepared plists compress far below this ratio. The generous ceiling
    // still prevents a tiny corrupt input from claiming a large output buffer.
    private static let maximumCompressionExpansionRatio = 512
    private static let minimumCompressedPayloadSize = 16

    static func encode(payload: Data, compressionEnabled: Bool = true) throws -> Data {
        guard payload.count <= maximumDecodedPayloadSize else {
            throw PreparedTileDiskCodecError.corruptedPayload("Prepared-tile payload is too large.")
        }
        let storedPayload: Data
        let algorithm: Algorithm
#if canImport(Compression)
        if compressionEnabled,
           let compressed = try? compressLZFSE(payload),
           compressed.count < payload.count,
           hasPlausibleCompressionSizes(storedByteCount: compressed.count,
                                        decodedByteCount: payload.count) {
            storedPayload = compressed
            algorithm = .lzfse
        } else {
            storedPayload = payload
            algorithm = .uncompressed
        }
#else
        // ImmersiveMap's supported platforms provide Compression/LZFSE. The
        // identity codec keeps the format usable by tooling on other hosts.
        storedPayload = payload
        algorithm = .uncompressed
#endif

        var encoded = Data()
        encoded.reserveCapacity(headerSize + storedPayload.count)
        encoded.append(magic)
        appendLittleEndian(currentVersion, to: &encoded)
        encoded.append(algorithm.rawValue)
        encoded.append(0) // flags, reserved for future envelope revisions
        appendLittleEndian(UInt64(payload.count), to: &encoded)
        appendLittleEndian(checksum(payload), to: &encoded)
        encoded.append(storedPayload)
        return encoded
    }

    /// Returns legacy data unchanged. Callers can therefore decode both the
    /// old raw binary plist and the new compressed envelope through one path.
    static func decode(data: Data) throws -> Data {
        guard isEnvelope(data) else {
            return data
        }
        guard data.count >= headerSize else {
            throw PreparedTileDiskCodecError.corruptedPayload("Truncated prepared-tile envelope.")
        }

        let version: UInt16 = try readLittleEndian(from: data, offset: 8)
        guard version == byteChecksumVersion || version == currentVersion else {
            throw PreparedTileDiskCodecError.corruptedPayload("Unsupported prepared-tile envelope version.")
        }
        guard let algorithm = Algorithm(rawValue: data[10]), data[11] == 0 else {
            throw PreparedTileDiskCodecError.corruptedPayload("Invalid prepared-tile envelope codec or flags.")
        }

        let decodedByteCount: UInt64 = try readLittleEndian(from: data, offset: 12)
        guard decodedByteCount <= UInt64(maximumDecodedPayloadSize),
              decodedByteCount <= UInt64(Int.max) else {
            throw PreparedTileDiskCodecError.corruptedPayload("Prepared-tile envelope is too large.")
        }
        let expectedChecksum: UInt64 = try readLittleEndian(from: data, offset: 20)
        let storedByteCount = data.count - headerSize

        let payload: Data
        switch algorithm {
        case .uncompressed:
            guard storedByteCount == Int(decodedByteCount) else {
                throw PreparedTileDiskCodecError.corruptedPayload(
                    "Prepared-tile uncompressed payload size does not match its header."
                )
            }
            payload = data.subdata(in: headerSize..<data.count)
        case .lzfse:
            guard hasPlausibleCompressionSizes(storedByteCount: storedByteCount,
                                                decodedByteCount: Int(decodedByteCount)) else {
                throw PreparedTileDiskCodecError.corruptedPayload(
                    "Prepared-tile envelope has an implausible compression ratio."
                )
            }
#if canImport(Compression)
            payload = try decompressLZFSE(data,
                                          sourceOffset: headerSize,
                                          sourceByteCount: storedByteCount,
                                          decodedByteCount: Int(decodedByteCount))
#else
            throw PreparedTileDiskCodecError.corruptedPayload("LZFSE is unavailable on this platform.")
#endif
        }

        let computedChecksum = version == byteChecksumVersion
            ? byteChecksum(payload)
            : checksum(payload)
        guard payload.count == Int(decodedByteCount), computedChecksum == expectedChecksum else {
            throw PreparedTileDiskCodecError.corruptedPayload("Prepared-tile envelope checksum mismatch.")
        }
        return payload
    }

    static func isEnvelope(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func isCompressedEnvelope(_ data: Data) -> Bool {
        isEnvelope(data) && data.count >= headerSize && data[10] == Algorithm.lzfse.rawValue
    }

    private static func hasPlausibleCompressionSizes(storedByteCount: Int,
                                                      decodedByteCount: Int) -> Bool {
        guard decodedByteCount > 0 else {
            return false
        }
        let minimumStoredByteCount = max(
            minimumCompressedPayloadSize,
            (decodedByteCount - 1) / maximumCompressionExpansionRatio + 1
        )
        return storedByteCount >= minimumStoredByteCount
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndian<T: FixedWidthInteger>(from data: Data, offset: Int) throws -> T {
        let endOffset = offset + MemoryLayout<T>.size
        guard offset >= 0, endOffset <= data.count else {
            throw PreparedTileDiskCodecError.corruptedPayload("Truncated prepared-tile envelope header.")
        }

        var value: T = 0
        for byteOffset in 0..<MemoryLayout<T>.size {
            value |= T(data[offset + byteOffset]) << (byteOffset * 8)
        }
        return value
    }

    /// FNV-1a over little-endian 8-byte words, used as a fast corruption
    /// check, not as a security primitive. The zero-padded tail cannot
    /// collide with genuine trailing zero bytes because the header stores the
    /// payload length and decode compares it before trusting the checksum.
    private static func checksum(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> UInt64 in
            var hash: UInt64 = 14_695_981_039_346_656_037
            let wordCount = buffer.count / 8
            for wordIndex in 0..<wordCount {
                let word = buffer.loadUnaligned(fromByteOffset: wordIndex * 8, as: UInt64.self)
                hash ^= UInt64(littleEndian: word)
                hash &*= 1_099_511_628_211
            }
            let tailStart = wordCount * 8
            if tailStart < buffer.count {
                var tail: UInt64 = 0
                for byteIndex in tailStart..<buffer.count {
                    tail |= UInt64(buffer[byteIndex]) << (UInt64(byteIndex - tailStart) * 8)
                }
                hash ^= tail
                hash &*= 1_099_511_628_211
            }
            return hash
        }
    }

    /// The byte-wise FNV-1a that version-1 envelopes were written with.
    private static func byteChecksum(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> UInt64 in
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in buffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }
    }

#if canImport(Compression)
    private static func compressLZFSE(_ source: Data) throws -> Data {
        guard source.isEmpty == false else {
            return Data()
        }

        let scratchByteCount = max(1, compression_encode_scratch_buffer_size(COMPRESSION_LZFSE))
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchByteCount,
                                                       alignment: MemoryLayout<UInt64>.alignment)
        defer { scratch.deallocate() }

        var capacity = max(256, source.count + max(64 * 1_024, source.count / 8))
        for _ in 0..<4 {
            var destination = Data(count: capacity)
            let encodedByteCount = destination.withUnsafeMutableBytes { destinationBytes in
                source.withUnsafeBytes { sourceBytes in
                    compression_encode_buffer(
                        destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                        destinationBytes.count,
                        sourceBytes.bindMemory(to: UInt8.self).baseAddress!,
                        sourceBytes.count,
                        scratch,
                        COMPRESSION_LZFSE
                    )
                }
            }
            if encodedByteCount > 0 {
                destination.removeSubrange(encodedByteCount..<destination.count)
                return destination
            }
            guard capacity <= Int.max / 2 else {
                break
            }
            capacity *= 2
        }
        throw PreparedTileDiskCodecError.corruptedPayload("Could not compress prepared-tile payload.")
    }

    private static func decompressLZFSE(_ source: Data,
                                        sourceOffset: Int,
                                        sourceByteCount: Int,
                                        decodedByteCount: Int) throws -> Data {
        guard sourceOffset >= 0,
              sourceByteCount > 0,
              sourceOffset <= source.count,
              sourceByteCount <= source.count - sourceOffset,
              decodedByteCount > 0 else {
            throw PreparedTileDiskCodecError.corruptedPayload("Invalid empty LZFSE prepared-tile payload.")
        }

        let scratchByteCount = max(1, compression_decode_scratch_buffer_size(COMPRESSION_LZFSE))
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchByteCount,
                                                       alignment: MemoryLayout<UInt64>.alignment)
        defer { scratch.deallocate() }

        var destination = Data(count: decodedByteCount)
        let actualByteCount = destination.withUnsafeMutableBytes { destinationBytes in
            source.withUnsafeBytes { sourceBytes in
                compression_decode_buffer(
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                    destinationBytes.count,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: sourceOffset),
                    sourceByteCount,
                    scratch,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard actualByteCount == decodedByteCount else {
            throw PreparedTileDiskCodecError.corruptedPayload("Could not decompress prepared-tile payload.")
        }
        return destination
    }
#endif
}

enum PreparedTileDiskCodec {
    struct Entry: Codable {
        let preparedFormatVersion: UInt32
        let styleRevision: UInt32
        let tileSourceRevision: UInt64
        let flatSeparateRoadRenderingMinimumZoom: UInt32
        let textRevision: UInt32
        let tileX: Int32
        let tileY: Int32
        let tileZ: Int32
        let labelLanguage: LabelLanguageValue
        let labelFallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy
        let houseNumbersEnabled: Bool
        let houseNumbersMinimumZoom: UInt32
        let addTestBorders: Bool
        // ETag of the raw tile this prepared tile was derived from; lets the cache
        // self-invalidate when the server content at the same URL changes.
        let sourceETag: String
        // The tile's GPU bytes as one arena image (see TileArenaImageMath):
        // a span table plus a blob that byte-matches the arena the factory
        // builds, so a hit copies or DMA-loads the blob instead of decoding
        // per-array fields.
        let arenaByteCount: UInt64
        let spanTable: [SpanValue]
        let geometryTransportRawValue: UInt8
        /// The arena image for the inline transport; empty when the blob
        /// lives in the sibling MTLIO container file.
        let geometryBlob: Data
        let textFull: TextLabelSetMetaValue
        let textReduced: TextLabelSetMetaValue
        let textMinimal: TextLabelSetMetaValue
        let roadPathInputs: Data
        let roadPathInputCount: UInt32
        let roadPathRanges: [RoadPathRangeValue]
        let roadPathLabels: [RoadPathLabelValue]
        let roadLabelStyle: LabelTextStyleValue?
        let roadGlyphBounds: Data
        let roadGlyphBoundsCount: UInt32
        let roadGlyphBoundRanges: [LabelGlyphRangeValue]
        let roadSizes: Data
        let roadSizeCount: UInt32
        let roadAnchorRanges: [RoadLabelAnchorRangeValue]
        let roadAnchors: [RoadLabelAnchorValue]
    }

    /// How the geometry blob of an entry is stored.
    enum GeometryBlobTransport: UInt8 {
        /// Inside the metadata envelope (`Entry.geometryBlob`); readable on
        /// every device, materialized with one CPU copy.
        case inline = 0
        /// As an MTLIO compression container in the sibling `.ptgeo` file,
        /// loaded straight into the arena buffer by `MTLIOCommandQueue`.
        case file = 1
    }

    struct SpanValue: Codable {
        let byteOffset: UInt64
        let byteCount: UInt64
        let elementCount: UInt32
        /// Present only on index spans; see `TileArenaIndexWidth`.
        let indexWidthRawValue: UInt8?

        init(_ span: TileArenaSpan) throws {
            byteOffset = UInt64(span.byteOffset)
            byteCount = UInt64(span.byteCount)
            elementCount = try encodeUInt32(span.elementCount, field: "Span.elementCount")
            indexWidthRawValue = span.indexWidth?.rawValue
        }

        func runtimeValue() throws -> TileArenaSpan {
            guard byteOffset <= UInt64(Int.max), byteCount <= UInt64(Int.max) else {
                throw PreparedTileDiskCodecError.corruptedPayload("Span range does not fit the platform word.")
            }
            let indexWidth: TileArenaIndexWidth?
            if let indexWidthRawValue {
                guard let width = TileArenaIndexWidth(rawValue: indexWidthRawValue) else {
                    throw PreparedTileDiskCodecError.corruptedPayload("Invalid span index width.")
                }
                indexWidth = width
            } else {
                indexWidth = nil
            }
            return TileArenaSpan(byteOffset: Int(byteOffset),
                                 byteCount: Int(byteCount),
                                 elementCount: Int(elementCount),
                                 indexWidth: indexWidth)
        }
    }

    struct TextLabelSetMetaValue: Codable {
        let placementInputs: [TextPlacementInputValue]
        let glyphRunStyles: [LabelTextStyleValue]
        let poiIconRunStyles: [LabelTextStyleValue]

        init(_ set: PreparedTileCPU.TextLabelSet) throws {
            placementInputs = try set.placementInputs.map(TextPlacementInputValue.init)
            glyphRunStyles = try set.glyphRuns.map { try LabelTextStyleValue($0.style) }
            poiIconRunStyles = try set.poiIconRuns.map { try LabelTextStyleValue($0.style) }
        }

        func runtimeValue() throws -> PreparedTileArenaImage.TextLabelSetMeta {
            PreparedTileArenaImage.TextLabelSetMeta(
                placementInputs: placementInputs.map { $0.runtimeValue() },
                glyphRunStyles: try glyphRunStyles.map { try $0.runtimeValue() },
                poiIconRunStyles: try poiIconRunStyles.map { try $0.runtimeValue() }
            )
        }
    }

    struct LabelLanguageValue: Codable {
        let code: String

        init(_ value: ImmersiveMapSettings.LabelLanguage) {
            code = value.code
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let encodedCode = try container.decode(String.self)
            switch encodedCode {
            case "english":
                code = ImmersiveMapSettings.LabelLanguage.english.code
            case "russian":
                code = ImmersiveMapSettings.LabelLanguage.russian.code
            default:
                code = ImmersiveMapSettings.LabelLanguage(encodedCode).code
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(code)
        }

        var runtimeValue: ImmersiveMapSettings.LabelLanguage {
            ImmersiveMapSettings.LabelLanguage(code)
        }
    }

    struct LabelTextStyleValue: Codable {
        let key: Int32
        let fillColor: [Float]
        let strokeColor: [Float]
        let strokeWidthPx: Float
        let sizePx: Float
        let weightRawValue: UInt8

        init(_ style: LabelTextStyle) throws {
            self.key = try encodeInt32(style.key, field: "LabelTextStyle.key")
            self.fillColor = [style.fillColor.x, style.fillColor.y, style.fillColor.z]
            self.strokeColor = [style.strokeColor.x, style.strokeColor.y, style.strokeColor.z]
            self.strokeWidthPx = style.strokeWidthPx
            self.sizePx = style.sizePx
            self.weightRawValue = style.weight.rawValue
        }

        func runtimeValue() throws -> LabelTextStyle {
            guard fillColor.count == 3, strokeColor.count == 3 else {
                throw PreparedTileDiskCodecError.corruptedPayload("Invalid LabelTextStyle color component count.")
            }
            guard let weight = LabelFontWeight(rawValue: weightRawValue) else {
                throw PreparedTileDiskCodecError.corruptedPayload("Invalid LabelFontWeight raw value.")
            }
            return LabelTextStyle(key: Int(key),
                                  fillColor: SIMD3<Float>(fillColor[0], fillColor[1], fillColor[2]),
                                  strokeColor: SIMD3<Float>(strokeColor[0], strokeColor[1], strokeColor[2]),
                                  strokeWidthPx: strokeWidthPx,
                                  sizePx: sizePx,
                                  weight: weight)
        }
    }

    struct TextPlacementInputValue: Codable {
        let uvX: Float
        let uvY: Float
        let tileX: Int32
        let tileY: Int32
        let tileZ: Int32
        let tileSlotIndex: UInt32
        let key: UInt64
        let sortKey: Int32
        let collisionPriority: Int32
        let labelWidthPx: Float
        let labelHeightPx: Float
        let minCameraZoom: Float

        init(_ input: TextLabelPlacementInput) throws {
            uvX = input.pointInput.uv.x
            uvY = input.pointInput.uv.y
            tileX = input.pointInput.tile.x
            tileY = input.pointInput.tile.y
            tileZ = input.pointInput.tile.z
            tileSlotIndex = input.pointInput.tileSlotIndex
            key = input.placementMeta.key
            sortKey = try encodeInt32(input.placementMeta.sortKey, field: "LabelPlacementMeta.sortKey")
            collisionPriority = try encodeInt32(input.placementMeta.collisionPriority, field: "LabelPlacementMeta.collisionPriority")
            labelWidthPx = input.placementMeta.labelSizePx.x
            labelHeightPx = input.placementMeta.labelSizePx.y
            minCameraZoom = input.placementMeta.minCameraZoom
        }

        func runtimeValue() -> TextLabelPlacementInput {
            TextLabelPlacementInput(
                pointInput: TilePointInput(uv: SIMD2<Float>(uvX, uvY),
                                           tile: SIMD3<Int32>(tileX, tileY, tileZ),
                                           tileSlotIndex: tileSlotIndex),
                placementMeta: LabelPlacementMeta(key: key,
                                                  sortKey: Int(sortKey),
                                                  collisionPriority: Int(collisionPriority),
                                                  labelSizePx: SIMD2<Float>(labelWidthPx, labelHeightPx),
                                                  minCameraZoom: minCameraZoom)
            )
        }
    }

    struct RoadPathRangeValue: Codable {
        let start: UInt32
        let count: UInt32
        let labelIndex: UInt32

        init(_ value: RoadPathRange) throws {
            start = try encodeUInt32(value.start, field: "RoadPathRange.start")
            count = try encodeUInt32(value.count, field: "RoadPathRange.count")
            labelIndex = try encodeUInt32(value.labelIndex, field: "RoadPathRange.labelIndex")
        }

        func runtimeValue() -> RoadPathRange {
            RoadPathRange(start: Int(start), count: Int(count), labelIndex: Int(labelIndex))
        }
    }

    struct RoadPathLabelValue: Codable {
        let text: String
        let key: UInt64

        init(_ value: RoadPathLabel) {
            text = value.text
            key = value.key
        }

        func runtimeValue() -> RoadPathLabel {
            RoadPathLabel(text: text, key: key)
        }
    }

    struct LabelGlyphRangeValue: Codable {
        let start: UInt32
        let count: UInt32

        init(_ value: LabelGlyphRange) throws {
            start = try encodeUInt32(value.start, field: "LabelGlyphRange.start")
            count = try encodeUInt32(value.count, field: "LabelGlyphRange.count")
        }

        func runtimeValue() -> LabelGlyphRange {
            LabelGlyphRange(start: Int(start), count: Int(count))
        }
    }

    struct RoadLabelAnchorRangeValue: Codable {
        let start: UInt32
        let count: UInt32

        init(_ value: RoadLabelAnchorRange) throws {
            start = try encodeUInt32(value.start, field: "RoadLabelAnchorRange.start")
            count = try encodeUInt32(value.count, field: "RoadLabelAnchorRange.count")
        }

        func runtimeValue() -> RoadLabelAnchorRange {
            RoadLabelAnchorRange(start: Int(start), count: Int(count))
        }
    }

    struct RoadLabelAnchorValue: Codable {
        let pathIndex: UInt32
        let segmentIndex: UInt32
        let t: Float
        let anchorOrdinal: UInt32

        init(_ value: RoadLabelAnchor) {
            pathIndex = value.pathIndex
            segmentIndex = value.segmentIndex
            t = value.t
            anchorOrdinal = value.anchorOrdinal
        }

        func runtimeValue() -> RoadLabelAnchor {
            RoadLabelAnchor(pathIndex: pathIndex,
                            segmentIndex: segmentIndex,
                            t: t,
                            anchorOrdinal: anchorOrdinal)
        }
    }

    /// The two artifacts of one encoded prepared tile: the metadata envelope
    /// (identity, span table, CPU-only label structures, and the blob itself
    /// for the inline transport) and the raw arena-image bytes for the file
    /// transport (empty for inline; the caller writes it as an MTLIO
    /// compression container next to the metadata).
    struct EncodedPreparedTile {
        let metadata: Data
        let fileBlob: Data
    }

    static func encode(preparedTile: PreparedTileCPU,
                       cacheIdentity: PreparedTileCacheIdentity,
                       sourceETag: String = "",
                       compressionEnabled: Bool = true,
                       blobTransport: GeometryBlobTransport = .inline) throws -> EncodedPreparedTile {
        let plan = TileArenaImageMath.plan(for: preparedTile)
        var blob = Data(count: plan.totalByteCount)
        if plan.totalByteCount > 0 {
            blob.withUnsafeMutableBytes { bytes in
                TileArenaImageMath.writeBlob(plan: plan, into: bytes.baseAddress!)
            }
        }

        let entry = try Entry(
            preparedFormatVersion: cacheIdentity.preparedFormatVersion,
            styleRevision: cacheIdentity.styleRevision,
            tileSourceRevision: cacheIdentity.tileSourceRevision,
            flatSeparateRoadRenderingMinimumZoom: cacheIdentity.flatSeparateRoadRenderingMinimumZoom,
            textRevision: cacheIdentity.textRevision,
            tileX: encodeInt32(preparedTile.tile.x, field: "Tile.x"),
            tileY: encodeInt32(preparedTile.tile.y, field: "Tile.y"),
            tileZ: encodeInt32(preparedTile.tile.z, field: "Tile.z"),
            labelLanguage: LabelLanguageValue(cacheIdentity.labelLanguage),
            labelFallbackPolicy: cacheIdentity.labelFallbackPolicy,
            houseNumbersEnabled: cacheIdentity.houseNumbersEnabled,
            houseNumbersMinimumZoom: cacheIdentity.houseNumbersMinimumZoom,
            addTestBorders: cacheIdentity.addTestBorders,
            sourceETag: sourceETag,
            arenaByteCount: UInt64(plan.totalByteCount),
            spanTable: plan.spans.map(SpanValue.init),
            geometryTransportRawValue: blobTransport.rawValue,
            geometryBlob: blobTransport == .inline ? blob : Data(),
            textFull: TextLabelSetMetaValue(preparedTile.textLabels.full),
            textReduced: TextLabelSetMetaValue(preparedTile.textLabels.reduced),
            textMinimal: TextLabelSetMetaValue(preparedTile.textLabels.minimal),
            roadPathInputs: encodePODArray(preparedTile.roadLabels.pathInputs),
            roadPathInputCount: encodeUInt32(preparedTile.roadLabels.pathInputs.count, field: "RoadLabels.pathInputs.count"),
            roadPathRanges: preparedTile.roadLabels.pathRanges.map(RoadPathRangeValue.init),
            roadPathLabels: preparedTile.roadLabels.pathLabels.map(RoadPathLabelValue.init),
            roadLabelStyle: preparedTile.roadLabels.labelStyle.map(LabelTextStyleValue.init),
            roadGlyphBounds: encodePODArray(preparedTile.roadLabels.glyphBounds),
            roadGlyphBoundsCount: encodeUInt32(preparedTile.roadLabels.glyphBounds.count, field: "RoadLabels.glyphBounds.count"),
            roadGlyphBoundRanges: preparedTile.roadLabels.glyphBoundRanges.map(LabelGlyphRangeValue.init),
            roadSizes: encodePODArray(preparedTile.roadLabels.sizes),
            roadSizeCount: encodeUInt32(preparedTile.roadLabels.sizes.count, field: "RoadLabels.sizes.count"),
            roadAnchorRanges: preparedTile.roadLabels.anchorRanges.map(RoadLabelAnchorRangeValue.init),
            roadAnchors: preparedTile.roadLabels.anchors.map(RoadLabelAnchorValue.init)
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(entry)
        let metadata = try PreparedTileDiskEnvelope.encode(payload: payload,
                                                           compressionEnabled: compressionEnabled)
        return EncodedPreparedTile(metadata: metadata,
                                   fileBlob: blobTransport == .file ? blob : Data())
    }

    static func decode(data: Data,
                       expectedTile: Tile,
                       cacheIdentity: PreparedTileCacheIdentity,
                       expectedSourceETag: String? = nil,
                       blobFileURL: URL) throws -> PreparedTileDiskCacheHit {
        let payload = try PreparedTileDiskEnvelope.decode(data: data)
        let decoder = PropertyListDecoder()
        let entry: Entry
        do {
            entry = try decoder.decode(Entry.self, from: payload)
        } catch let error as PreparedTileDiskCodecError {
            throw error
        } catch {
            throw PreparedTileDiskCodecError.corruptedPayload("Invalid prepared-tile property list.")
        }

        guard entry.preparedFormatVersion == cacheIdentity.preparedFormatVersion,
              entry.styleRevision == cacheIdentity.styleRevision,
              entry.tileSourceRevision == cacheIdentity.tileSourceRevision,
              entry.flatSeparateRoadRenderingMinimumZoom == cacheIdentity.flatSeparateRoadRenderingMinimumZoom,
              entry.textRevision == cacheIdentity.textRevision,
              entry.tileX == Int32(expectedTile.x),
              entry.tileY == Int32(expectedTile.y),
              entry.tileZ == Int32(expectedTile.z),
              entry.labelLanguage.runtimeValue == cacheIdentity.labelLanguage,
              entry.labelFallbackPolicy == cacheIdentity.labelFallbackPolicy,
              entry.houseNumbersEnabled == cacheIdentity.houseNumbersEnabled,
              entry.houseNumbersMinimumZoom == cacheIdentity.houseNumbersMinimumZoom,
              entry.addTestBorders == cacheIdentity.addTestBorders,
              expectedSourceETag.map({ entry.sourceETag == $0 }) ?? true else {
            throw PreparedTileDiskCodecError.invalidMetadata
        }

        guard entry.arenaByteCount <= UInt64(Int.max) else {
            throw PreparedTileDiskCodecError.corruptedPayload("Arena byte count does not fit the platform word.")
        }
        let arenaByteCount = Int(entry.arenaByteCount)
        let spans = try entry.spanTable.map { try $0.runtimeValue() }
        try validate(spans: spans, arenaByteCount: arenaByteCount)

        guard let transport = GeometryBlobTransport(rawValue: entry.geometryTransportRawValue) else {
            throw PreparedTileDiskCodecError.corruptedPayload("Unknown geometry blob transport.")
        }
        let blob: PreparedTileArenaImage.GeometryBlob
        switch transport {
        case .inline:
            guard entry.geometryBlob.count == arenaByteCount else {
                throw PreparedTileDiskCodecError.corruptedPayload("Inline geometry blob size mismatch.")
            }
            blob = .inline(entry.geometryBlob)
        case .file:
            guard entry.geometryBlob.isEmpty else {
                throw PreparedTileDiskCodecError.corruptedPayload("File-transport entry carries an inline blob.")
            }
            blob = .file(blobFileURL)
        }

        let image = PreparedTileArenaImage(
            tile: expectedTile,
            spans: spans,
            arenaByteCount: arenaByteCount,
            textLabelsFull: try entry.textFull.runtimeValue(),
            textLabelsReduced: try entry.textReduced.runtimeValue(),
            textLabelsMinimal: try entry.textMinimal.runtimeValue(),
            roadLabels: PreparedTileArenaImage.RoadLabelsMeta(
                pathInputs: try decodePODArray(entry.roadPathInputs,
                                               count: Int(entry.roadPathInputCount),
                                               as: TilePointInput.self,
                                               field: "Entry.roadPathInputs"),
                pathRanges: entry.roadPathRanges.map { $0.runtimeValue() },
                pathLabels: entry.roadPathLabels.map { $0.runtimeValue() },
                labelStyle: try entry.roadLabelStyle?.runtimeValue(),
                glyphBounds: try decodePODArray(entry.roadGlyphBounds,
                                                count: Int(entry.roadGlyphBoundsCount),
                                                as: SIMD4<Float>.self,
                                                field: "Entry.roadGlyphBounds"),
                glyphBoundRanges: entry.roadGlyphBoundRanges.map { $0.runtimeValue() },
                sizes: try decodePODArray(entry.roadSizes,
                                          count: Int(entry.roadSizeCount),
                                          as: SIMD2<Float>.self,
                                          field: "Entry.roadSizes"),
                anchorRanges: entry.roadAnchorRanges.map { $0.runtimeValue() },
                anchors: entry.roadAnchors.map { $0.runtimeValue() }
            ),
            blob: blob
        )
        return PreparedTileDiskCacheHit(image: image,
                                        sourceETag: entry.sourceETag.isEmpty ? nil : entry.sourceETag)
    }

    /// Structural validation of an untrusted span table: spans must ascend
    /// without overlap, start aligned, and stay inside the arena. Element
    /// strides are checked later by the factory, which knows each span's
    /// slot type.
    private static func validate(spans: [TileArenaSpan], arenaByteCount: Int) throws {
        var expectedNextOffset = 0
        for span in spans {
            guard span.byteOffset == expectedNextOffset,
                  span.byteCount >= 0,
                  span.elementCount >= 0,
                  (span.elementCount == 0) == (span.byteCount == 0),
                  span.byteOffset % TileArenaImageMath.spanAlignment == 0,
                  span.byteCount <= arenaByteCount - span.byteOffset else {
                throw PreparedTileDiskCodecError.corruptedPayload("Invalid arena span table.")
            }
            expectedNextOffset = span.byteOffset + TileArenaImageMath.alignedByteCount(span.byteCount)
        }
        guard expectedNextOffset == arenaByteCount else {
            throw PreparedTileDiskCodecError.corruptedPayload("Arena span table does not cover the arena.")
        }
    }

    private static func encodePODArray<T>(_ values: [T]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private static func decodePODArray<T>(_ data: Data,
                                          count: Int,
                                          as _: T.Type,
                                          field: String) throws -> [T] {
        let stride = MemoryLayout<T>.stride
        guard count >= 0, data.count == count * stride else {
            throw PreparedTileDiskCodecError.corruptedPayload("Invalid byte count for \(field).")
        }
        guard count > 0 else {
            return []
        }

        return data.withUnsafeBytes { sourceBytes in
            Array<T>(unsafeUninitializedCapacity: count) { buffer, initializedCount in
                let destination = UnsafeMutableRawBufferPointer(buffer)
                destination.copyBytes(from: sourceBytes)
                initializedCount = count
            }
        }
    }

    private static func encodeInt32(_ value: Int, field: String) throws -> Int32 {
        guard let encoded = Int32(exactly: value) else {
            throw PreparedTileDiskCodecError.invalidField(field)
        }
        return encoded
    }

    private static func encodeUInt32(_ value: Int, field: String) throws -> UInt32 {
        guard let encoded = UInt32(exactly: value) else {
            throw PreparedTileDiskCodecError.invalidField(field)
        }
        return encoded
    }
}
