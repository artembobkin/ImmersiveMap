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
    private static let currentVersion: UInt16 = 1
    private static let headerSize = 28
    // A prepared tile is a cache artifact for one source tile. 64 MiB leaves
    // ample room for dense geometry while bounding any single decode allocation.
    private static let maximumDecodedPayloadSize = 64 * 1_024 * 1_024
    // Real prepared plists compress far below this ratio. The generous ceiling
    // still prevents a tiny corrupt input from claiming a large output buffer.
    private static let maximumCompressionExpansionRatio = 512
    private static let minimumCompressedPayloadSize = 16

    static func encode(payload: Data) throws -> Data {
        guard payload.count <= maximumDecodedPayloadSize else {
            throw PreparedTileDiskCodecError.corruptedPayload("Prepared-tile payload is too large.")
        }
        let storedPayload: Data
        let algorithm: Algorithm
#if canImport(Compression)
        if let compressed = try? compressLZFSE(payload),
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
        guard version == currentVersion else {
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

        guard payload.count == Int(decodedByteCount), checksum(payload) == expectedChecksum else {
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

    /// FNV-1a is used as a fast corruption check, not as a security primitive.
    private static func checksum(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
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
        let groundVertices: Data
        let groundVertexCount: UInt32
        let groundIndices: Data
        let groundIndexCount: UInt32
        let groundStyles: Data
        let groundStyleCount: UInt32
        let groundOverviewStyleMasks: Data
        let groundOverviewStyleMaskCount: UInt32
        let roads: RoadStructureBucketsValue
        let bridgeVertices: Data
        let bridgeVertexCount: UInt32
        let bridgeIndices: Data
        let bridgeIndexCount: UInt32
        let bridgeStyles: Data
        let bridgeStyleCount: UInt32
        let bridgeOverviewStyleMasks: Data
        let bridgeOverviewStyleMaskCount: UInt32
        let extrudedVertices: Data
        let extrudedVertexCount: UInt32
        let extrudedIndices: Data
        let extrudedIndexCount: UInt32
        let extrudedStyles: Data
        let extrudedStyleCount: UInt32
        let textFull: TextLabelSetValue
        let textReduced: TextLabelSetValue
        let textMinimal: TextLabelSetValue
        let roadPathInputs: Data
        let roadPathInputCount: UInt32
        let roadPathRanges: [RoadPathRangeValue]
        let roadPathLabels: [RoadPathLabelValue]
        let roadLabelStyle: LabelTextStyleValue?
        let roadGlyphVertices: Data
        let roadGlyphVertexCount: UInt32
        let roadGlyphBounds: Data
        let roadGlyphBoundsCount: UInt32
        let roadGlyphBoundRanges: [LabelGlyphRangeValue]
        let roadSizes: Data
        let roadSizeCount: UInt32
        let roadAnchorRanges: [RoadLabelAnchorRangeValue]
        let roadAnchors: [RoadLabelAnchorValue]
    }

    struct GeometryLayerValue: Codable {
        let vertices: Data
        let vertexCount: UInt32
        let indices: Data
        let indexCount: UInt32
        let styles: Data
        let styleCount: UInt32
        let overviewStyleMasks: Data
        let overviewStyleMaskCount: UInt32

        init(vertices: Data,
             vertexCount: UInt32,
             indices: Data,
             indexCount: UInt32,
             styles: Data,
             styleCount: UInt32,
             overviewStyleMasks: Data,
             overviewStyleMaskCount: UInt32) {
            self.vertices = vertices
            self.vertexCount = vertexCount
            self.indices = indices
            self.indexCount = indexCount
            self.styles = styles
            self.styleCount = styleCount
            self.overviewStyleMasks = overviewStyleMasks
            self.overviewStyleMaskCount = overviewStyleMaskCount
        }

        init(_ layer: PreparedTileCPU.GeometryLayer, fieldPrefix: String) throws {
            vertices = encodePODArray(layer.vertices)
            vertexCount = try encodeUInt32(layer.vertices.count, field: "\(fieldPrefix).vertices.count")
            indices = encodePODArray(layer.indices)
            indexCount = try encodeUInt32(layer.indices.count, field: "\(fieldPrefix).indices.count")
            styles = encodePODArray(layer.styles)
            styleCount = try encodeUInt32(layer.styles.count, field: "\(fieldPrefix).styles.count")
            overviewStyleMasks = encodePODArray(layer.overviewStyleMasks)
            overviewStyleMaskCount = try encodeUInt32(layer.overviewStyleMasks.count,
                                                      field: "\(fieldPrefix).overviewStyleMasks.count")
        }

        func runtimeValue(fieldPrefix: String) throws -> PreparedTileCPU.GeometryLayer {
            PreparedTileCPU.GeometryLayer(
                vertices: try decodePODArray(vertices,
                                             count: Int(vertexCount),
                                             as: TilePipeline.VertexIn.self,
                                             field: "\(fieldPrefix).vertices"),
                indices: try decodePODArray(indices,
                                            count: Int(indexCount),
                                            as: UInt32.self,
                                            field: "\(fieldPrefix).indices"),
                styles: try decodePODArray(styles,
                                           count: Int(styleCount),
                                           as: TilePolygonStyle.self,
                                           field: "\(fieldPrefix).styles"),
                overviewStyleMasks: try decodePODArray(overviewStyleMasks,
                                                       count: Int(overviewStyleMaskCount),
                                                       as: Float.self,
                                                       field: "\(fieldPrefix).overviewStyleMasks")
            )
        }
    }

    struct RoadGeometryPhasesValue: Codable {
        let shadow: GeometryLayerValue
        let casing: GeometryLayerValue
        let fill: GeometryLayerValue
        let detail: GeometryLayerValue
        let overlay: GeometryLayerValue

        init(_ phases: RoadGeometryPhases<PreparedTileCPU.GeometryLayer>) throws {
            shadow = try GeometryLayerValue(phases.shadow, fieldPrefix: "Roads.shadow")
            casing = try GeometryLayerValue(phases.casing, fieldPrefix: "Roads.casing")
            fill = try GeometryLayerValue(phases.fill, fieldPrefix: "Roads.fill")
            detail = try GeometryLayerValue(phases.detail, fieldPrefix: "Roads.detail")
            overlay = try GeometryLayerValue(phases.overlay, fieldPrefix: "Roads.overlay")
        }

        func runtimeValue() throws -> RoadGeometryPhases<PreparedTileCPU.GeometryLayer> {
            RoadGeometryPhases(
                shadow: try shadow.runtimeValue(fieldPrefix: "Entry.roads.shadow"),
                casing: try casing.runtimeValue(fieldPrefix: "Entry.roads.casing"),
                fill: try fill.runtimeValue(fieldPrefix: "Entry.roads.fill"),
                detail: try detail.runtimeValue(fieldPrefix: "Entry.roads.detail"),
                overlay: try overlay.runtimeValue(fieldPrefix: "Entry.roads.overlay")
            )
        }
    }

    struct RoadStructureBucketsValue: Codable {
        let tunnel: RoadGeometryPhasesValue
        let ground: RoadGeometryPhasesValue
        let bridge: RoadGeometryPhasesValue

        init(_ buckets: RoadStructureBuckets<RoadGeometryPhases<PreparedTileCPU.GeometryLayer>>) throws {
            tunnel = try RoadGeometryPhasesValue(buckets.tunnel)
            ground = try RoadGeometryPhasesValue(buckets.ground)
            bridge = try RoadGeometryPhasesValue(buckets.bridge)
        }

        func runtimeValue() throws -> RoadStructureBuckets<RoadGeometryPhases<PreparedTileCPU.GeometryLayer>> {
            RoadStructureBuckets(
                tunnel: try tunnel.runtimeValue(),
                ground: try ground.runtimeValue(),
                bridge: try bridge.runtimeValue()
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
        }

        func runtimeValue() -> TextLabelPlacementInput {
            TextLabelPlacementInput(
                pointInput: TilePointInput(uv: SIMD2<Float>(uvX, uvY),
                                           tile: SIMD3<Int32>(tileX, tileY, tileZ),
                                           tileSlotIndex: tileSlotIndex),
                placementMeta: LabelPlacementMeta(key: key,
                                                  sortKey: Int(sortKey),
                                                  collisionPriority: Int(collisionPriority),
                                                  labelSizePx: SIMD2<Float>(labelWidthPx, labelHeightPx))
            )
        }
    }

    struct TextGlyphRunValue: Codable {
        let style: LabelTextStyleValue
        let localGlyphVertices: Data
        let localGlyphVertexCount: UInt32

        init(_ run: PreparedTileCPU.TextGlyphRun) throws {
            style = try LabelTextStyleValue(run.style)
            localGlyphVertices = encodePODArray(run.localGlyphVertices)
            localGlyphVertexCount = try encodeUInt32(run.localGlyphVertices.count, field: "TextGlyphRun.localGlyphVertices.count")
        }

        func runtimeValue() throws -> PreparedTileCPU.TextGlyphRun {
            PreparedTileCPU.TextGlyphRun(style: try style.runtimeValue(),
                                         localGlyphVertices: try decodePODArray(localGlyphVertices,
                                                                                count: Int(localGlyphVertexCount),
                                                                                as: LabelVertex.self,
                                                                                field: "TextGlyphRun.localGlyphVertices"))
        }
    }

    struct TextPoiIconRunValue: Codable {
        let style: LabelTextStyleValue
        let localIconVertices: Data
        let localIconVertexCount: UInt32

        init(_ run: PreparedTileCPU.PoiIconRun) throws {
            style = try LabelTextStyleValue(run.style)
            localIconVertices = encodePODArray(run.localIconVertices)
            localIconVertexCount = try encodeUInt32(run.localIconVertices.count, field: "TextPoiIconRun.localIconVertices.count")
        }

        func runtimeValue() throws -> PreparedTileCPU.PoiIconRun {
            PreparedTileCPU.PoiIconRun(style: try style.runtimeValue(),
                                       localIconVertices: try decodePODArray(localIconVertices,
                                                                             count: Int(localIconVertexCount),
                                                                             as: LabelVertex.self,
                                                                             field: "TextPoiIconRun.localIconVertices"))
        }
    }

    struct TextLabelSetValue: Codable {
        let placementInputs: [TextPlacementInputValue]
        let glyphRuns: [TextGlyphRunValue]
        let poiIconRuns: [TextPoiIconRunValue]

        init(_ set: PreparedTileCPU.TextLabelSet) throws {
            placementInputs = try set.placementInputs.map(TextPlacementInputValue.init)
            glyphRuns = try set.glyphRuns.map(TextGlyphRunValue.init)
            poiIconRuns = try set.poiIconRuns.map(TextPoiIconRunValue.init)
        }

        func runtimeValue() throws -> PreparedTileCPU.TextLabelSet {
            PreparedTileCPU.TextLabelSet(placementInputs: placementInputs.map { $0.runtimeValue() },
                                         glyphRuns: try glyphRuns.map { try $0.runtimeValue() },
                                         poiIconRuns: try poiIconRuns.map { try $0.runtimeValue() })
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
        let distanceAlongPath: Float
        let anchorOrdinal: UInt32

        init(_ value: RoadLabelAnchor) {
            pathIndex = value.pathIndex
            segmentIndex = value.segmentIndex
            t = value.t
            distanceAlongPath = value.distanceAlongPath
            anchorOrdinal = value.anchorOrdinal
        }

        func runtimeValue() -> RoadLabelAnchor {
            RoadLabelAnchor(pathIndex: pathIndex,
                            segmentIndex: segmentIndex,
                            t: t,
                            distanceAlongPath: distanceAlongPath,
                            anchorOrdinal: anchorOrdinal)
        }
    }

    static func encode(preparedTile: PreparedTileCPU,
                       cacheIdentity: PreparedTileCacheIdentity,
                       sourceETag: String = "") throws -> Data {
        let payload = try encodeLegacyPropertyList(preparedTile: preparedTile,
                                                   cacheIdentity: cacheIdentity,
                                                   sourceETag: sourceETag)
        return try PreparedTileDiskEnvelope.encode(payload: payload)
    }

    /// The pre-envelope representation. Kept internal so compatibility can be
    /// regression-tested and old cache files remain a first-class decode path.
    static func encodeLegacyPropertyList(preparedTile: PreparedTileCPU,
                                         cacheIdentity: PreparedTileCacheIdentity,
                                         sourceETag: String = "") throws -> Data {
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
            groundVertices: encodePODArray(preparedTile.ground.vertices),
            groundVertexCount: encodeUInt32(preparedTile.ground.vertices.count, field: "Ground.vertices.count"),
            groundIndices: encodePODArray(preparedTile.ground.indices),
            groundIndexCount: encodeUInt32(preparedTile.ground.indices.count, field: "Ground.indices.count"),
            groundStyles: encodePODArray(preparedTile.ground.styles),
            groundStyleCount: encodeUInt32(preparedTile.ground.styles.count, field: "Ground.styles.count"),
            groundOverviewStyleMasks: encodePODArray(preparedTile.ground.overviewStyleMasks),
            groundOverviewStyleMaskCount: encodeUInt32(preparedTile.ground.overviewStyleMasks.count,
                                                       field: "Ground.overviewStyleMasks.count"),
            roads: try RoadStructureBucketsValue(preparedTile.roads),
            bridgeVertices: encodePODArray(preparedTile.bridgeOverlay.vertices),
            bridgeVertexCount: encodeUInt32(preparedTile.bridgeOverlay.vertices.count, field: "BridgeOverlay.vertices.count"),
            bridgeIndices: encodePODArray(preparedTile.bridgeOverlay.indices),
            bridgeIndexCount: encodeUInt32(preparedTile.bridgeOverlay.indices.count, field: "BridgeOverlay.indices.count"),
            bridgeStyles: encodePODArray(preparedTile.bridgeOverlay.styles),
            bridgeStyleCount: encodeUInt32(preparedTile.bridgeOverlay.styles.count, field: "BridgeOverlay.styles.count"),
            bridgeOverviewStyleMasks: encodePODArray(preparedTile.bridgeOverlay.overviewStyleMasks),
            bridgeOverviewStyleMaskCount: encodeUInt32(preparedTile.bridgeOverlay.overviewStyleMasks.count,
                                                       field: "BridgeOverlay.overviewStyleMasks.count"),
            extrudedVertices: encodePODArray(preparedTile.extruded.vertices),
            extrudedVertexCount: encodeUInt32(preparedTile.extruded.vertices.count, field: "Extruded.vertices.count"),
            extrudedIndices: encodePODArray(preparedTile.extruded.indices),
            extrudedIndexCount: encodeUInt32(preparedTile.extruded.indices.count, field: "Extruded.indices.count"),
            extrudedStyles: encodePODArray(preparedTile.extruded.styles),
            extrudedStyleCount: encodeUInt32(preparedTile.extruded.styles.count, field: "Extruded.styles.count"),
            textFull: try TextLabelSetValue(preparedTile.textLabels.full),
            textReduced: try TextLabelSetValue(preparedTile.textLabels.reduced),
            textMinimal: try TextLabelSetValue(preparedTile.textLabels.minimal),
            roadPathInputs: encodePODArray(preparedTile.roadLabels.pathInputs),
            roadPathInputCount: encodeUInt32(preparedTile.roadLabels.pathInputs.count, field: "RoadLabels.pathInputs.count"),
            roadPathRanges: try preparedTile.roadLabels.pathRanges.map(RoadPathRangeValue.init),
            roadPathLabels: preparedTile.roadLabels.pathLabels.map(RoadPathLabelValue.init),
            roadLabelStyle: try preparedTile.roadLabels.labelStyle.map(LabelTextStyleValue.init),
            roadGlyphVertices: encodePODArray(preparedTile.roadLabels.localGlyphVertices),
            roadGlyphVertexCount: encodeUInt32(preparedTile.roadLabels.localGlyphVertices.count, field: "RoadLabels.localGlyphVertices.count"),
            roadGlyphBounds: encodePODArray(preparedTile.roadLabels.glyphBounds),
            roadGlyphBoundsCount: encodeUInt32(preparedTile.roadLabels.glyphBounds.count, field: "RoadLabels.glyphBounds.count"),
            roadGlyphBoundRanges: try preparedTile.roadLabels.glyphBoundRanges.map(LabelGlyphRangeValue.init),
            roadSizes: encodePODArray(preparedTile.roadLabels.sizes),
            roadSizeCount: encodeUInt32(preparedTile.roadLabels.sizes.count, field: "RoadLabels.sizes.count"),
            roadAnchorRanges: try preparedTile.roadLabels.anchorRanges.map(RoadLabelAnchorRangeValue.init),
            roadAnchors: preparedTile.roadLabels.anchors.map(RoadLabelAnchorValue.init)
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(entry)
    }

    static func decode(data: Data,
                       expectedTile: Tile,
                       cacheIdentity: PreparedTileCacheIdentity,
                       expectedSourceETag: String? = nil) throws -> PreparedTileCPU {
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

        return PreparedTileCPU(
            tile: expectedTile,
            ground: try GeometryLayerValue(vertices: entry.groundVertices,
                                           vertexCount: entry.groundVertexCount,
                                           indices: entry.groundIndices,
                                           indexCount: entry.groundIndexCount,
                                           styles: entry.groundStyles,
                                           styleCount: entry.groundStyleCount,
                                           overviewStyleMasks: entry.groundOverviewStyleMasks,
                                           overviewStyleMaskCount: entry.groundOverviewStyleMaskCount)
                .runtimeValue(fieldPrefix: "Entry.ground"),
            roads: try entry.roads.runtimeValue(),
            bridgeOverlay: try GeometryLayerValue(vertices: entry.bridgeVertices,
                                                  vertexCount: entry.bridgeVertexCount,
                                                  indices: entry.bridgeIndices,
                                                  indexCount: entry.bridgeIndexCount,
                                                  styles: entry.bridgeStyles,
                                                  styleCount: entry.bridgeStyleCount,
                                                  overviewStyleMasks: entry.bridgeOverviewStyleMasks,
                                                  overviewStyleMaskCount: entry.bridgeOverviewStyleMaskCount)
                .runtimeValue(fieldPrefix: "Entry.bridgeOverlay"),
            extruded: PreparedTileCPU.Extruded(
                vertices: try decodePODArray(entry.extrudedVertices,
                                             count: Int(entry.extrudedVertexCount),
                                             as: TileMvtParser.ExtrudedVertexIn.self,
                                             field: "Entry.extrudedVertices"),
                indices: try decodePODArray(entry.extrudedIndices,
                                            count: Int(entry.extrudedIndexCount),
                                            as: UInt32.self,
                                            field: "Entry.extrudedIndices"),
                styles: try decodePODArray(entry.extrudedStyles,
                                           count: Int(entry.extrudedStyleCount),
                                           as: TilePolygonStyle.self,
                                           field: "Entry.extrudedStyles")
            ),
            textLabels: PreparedTileCPU.TextLabels(full: try entry.textFull.runtimeValue(),
                                                   reduced: try entry.textReduced.runtimeValue(),
                                                   minimal: try entry.textMinimal.runtimeValue()),
            roadLabels: PreparedTileCPU.RoadLabels(
                pathInputs: try decodePODArray(entry.roadPathInputs,
                                               count: Int(entry.roadPathInputCount),
                                               as: TilePointInput.self,
                                               field: "Entry.roadPathInputs"),
                pathRanges: entry.roadPathRanges.map { $0.runtimeValue() },
                pathLabels: entry.roadPathLabels.map { $0.runtimeValue() },
                labelStyle: try entry.roadLabelStyle?.runtimeValue(),
                localGlyphVertices: try decodePODArray(entry.roadGlyphVertices,
                                                       count: Int(entry.roadGlyphVertexCount),
                                                       as: LabelVertex.self,
                                                       field: "Entry.roadGlyphVertices"),
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
            )
        )
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
