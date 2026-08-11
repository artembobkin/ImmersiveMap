// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum MvtWireDecodeError: Error {
    case truncatedVarint
    case malformedVarint
    case truncatedField
    case invalidWireType
    case unmatchedGroupEnd
    case groupNestingTooDeep
    /// The layer message misses a proto2 `required` field (version or name),
    /// mirroring swift-protobuf's missing-required-fields failure.
    case missingRequiredLayerField
}

/// Hand-written decoder for the Mapbox Vector Tile protobuf schema.
///
/// The generated swift-protobuf decode materializes every feature's `tags`
/// and `geometry` as fresh `[UInt32]` arrays; on a dense city tile that is
/// thousands of short-lived allocations per parse, thrown away right after
/// the geometry pass converts them again. This decoder walks the wire format
/// once via `withUnsafeBytes` and leaves packed fields as byte ranges into
/// the payload; `MvtGeometryDecoder` then decodes rings straight from those
/// bytes.
///
/// Behavior mirrors `VectorTile_Tile(serializedBytes:)` for valid tiles:
/// packed and unpacked repeated encodings, split packed runs, last-one-wins
/// scalars, unknown fields (including nested groups) skipped, truncated or
/// malformed input throws, and a layer without the required `version`/`name`
/// throws. The one deliberate divergence: invalid UTF-8 in strings decodes
/// with replacement characters instead of failing the whole tile.
enum MvtTileDecoder {
    private static let lengthDelimitedWireType: UInt64 = 2
    private static let maximumGroupNestingDepth = 32

    static func decode(data: Data) throws -> MvtDecodedTile {
        let layers = try data.withUnsafeBytes { bytes in
            try decodeTile(bytes: bytes)
        }
        return MvtDecodedTile(layers: layers, sourceData: data)
    }

    // MARK: - Message decoding

    private static func decodeTile(bytes: UnsafeRawBufferPointer) throws -> [MvtDecodedLayer] {
        var layers: [MvtDecodedLayer] = []
        var offset = 0
        let end = bytes.count

        while offset < end {
            let tag = try readVarint(bytes, &offset, end: end)
            let fieldNumber = tag >> 3
            let wireType = tag & 7

            if fieldNumber == 3, wireType == lengthDelimitedWireType {
                let range = try readLengthDelimited(bytes, &offset, end: end)
                layers.append(try decodeLayer(bytes: bytes, range: range))
            } else {
                try skipField(bytes, &offset, end: end, wireType: wireType)
            }
        }

        return layers
    }

    private static func decodeLayer(bytes: UnsafeRawBufferPointer, range: Range<Int>) throws -> MvtDecodedLayer {
        var layer = MvtDecodedLayer()
        var hasVersion = false
        var hasName = false
        var offset = range.lowerBound
        let end = range.upperBound

        while offset < end {
            let tag = try readVarint(bytes, &offset, end: end)
            let fieldNumber = tag >> 3
            let wireType = tag & 7

            switch (fieldNumber, wireType) {
            case (1, lengthDelimitedWireType):
                let stringRange = try readLengthDelimited(bytes, &offset, end: end)
                layer.name = decodeString(bytes, range: stringRange)
                hasName = true
            case (2, lengthDelimitedWireType):
                let featureRange = try readLengthDelimited(bytes, &offset, end: end)
                layer.features.append(try decodeFeature(bytes: bytes, range: featureRange))
            case (3, lengthDelimitedWireType):
                let stringRange = try readLengthDelimited(bytes, &offset, end: end)
                layer.keys.append(decodeString(bytes, range: stringRange))
            case (4, lengthDelimitedWireType):
                let valueRange = try readLengthDelimited(bytes, &offset, end: end)
                layer.values.append(try decodeValue(bytes: bytes, range: valueRange))
            case (5, 0):
                layer.extent = UInt32(truncatingIfNeeded: try readVarint(bytes, &offset, end: end))
            case (15, 0):
                _ = try readVarint(bytes, &offset, end: end)
                hasVersion = true
            default:
                try skipField(bytes, &offset, end: end, wireType: wireType)
            }
        }

        guard hasVersion, hasName else {
            throw MvtWireDecodeError.missingRequiredLayerField
        }
        return layer
    }

    private static func decodeFeature(bytes: UnsafeRawBufferPointer, range: Range<Int>) throws -> MvtDecodedFeature {
        var feature = MvtDecodedFeature()
        var offset = range.lowerBound
        let end = range.upperBound

        while offset < end {
            let tag = try readVarint(bytes, &offset, end: end)
            let fieldNumber = tag >> 3
            let wireType = tag & 7

            switch (fieldNumber, wireType) {
            case (1, 0):
                feature.id = try readVarint(bytes, &offset, end: end)
                feature.hasID = true
            case (2, lengthDelimitedWireType):
                let packedRange = try readLengthDelimited(bytes, &offset, end: end)
                feature.tags = appendPackedRun(to: feature.tags, run: packedRange, bytes: bytes)
            case (2, 0):
                let value = UInt32(truncatingIfNeeded: try readVarint(bytes, &offset, end: end))
                feature.tags = appendUnpackedElement(to: feature.tags, value: value, bytes: bytes)
            case (3, 0):
                let rawType = Int(truncatingIfNeeded: try readVarint(bytes, &offset, end: end))
                // proto2 keeps unrecognized enum values out of the field, so
                // an invalid geometry type leaves the previous value alone.
                if let geomType = VectorTile_Tile.GeomType(rawValue: rawType) {
                    feature.type = geomType
                }
            case (4, lengthDelimitedWireType):
                let packedRange = try readLengthDelimited(bytes, &offset, end: end)
                feature.geometry = appendPackedRun(to: feature.geometry, run: packedRange, bytes: bytes)
            case (4, 0):
                let value = UInt32(truncatingIfNeeded: try readVarint(bytes, &offset, end: end))
                feature.geometry = appendUnpackedElement(to: feature.geometry, value: value, bytes: bytes)
            default:
                try skipField(bytes, &offset, end: end, wireType: wireType)
            }
        }

        return feature
    }

    private static func decodeValue(bytes: UnsafeRawBufferPointer, range: Range<Int>) throws -> VectorTile_Tile.Value {
        var value = VectorTile_Tile.Value()
        var offset = range.lowerBound
        let end = range.upperBound

        while offset < end {
            let tag = try readVarint(bytes, &offset, end: end)
            let fieldNumber = tag >> 3
            let wireType = tag & 7

            switch (fieldNumber, wireType) {
            case (1, lengthDelimitedWireType):
                let stringRange = try readLengthDelimited(bytes, &offset, end: end)
                value.stringValue = decodeString(bytes, range: stringRange)
            case (2, 5):
                value.floatValue = Float(bitPattern: try readFixed32(bytes, &offset, end: end))
            case (3, 1):
                value.doubleValue = Double(bitPattern: try readFixed64(bytes, &offset, end: end))
            case (4, 0):
                value.intValue = Int64(bitPattern: try readVarint(bytes, &offset, end: end))
            case (5, 0):
                value.uintValue = try readVarint(bytes, &offset, end: end)
            case (6, 0):
                value.sintValue = decodeZigZag64(try readVarint(bytes, &offset, end: end))
            case (7, 0):
                value.boolValue = try readVarint(bytes, &offset, end: end) != 0
            default:
                try skipField(bytes, &offset, end: end, wireType: wireType)
            }
        }

        return value
    }

    // MARK: - Packed field accumulation

    /// The first packed run stays a byte range; a second run (or a mix with
    /// unpacked elements) falls back to materializing, which the wire format
    /// requires treating as one concatenated field.
    private static func appendPackedRun(to field: MvtPackedField,
                                        run: Range<Int>,
                                        bytes: UnsafeRawBufferPointer) -> MvtPackedField {
        switch field {
        case .empty:
            return .range(run)
        case .range(let existing):
            var values = materialize(range: existing, bytes: bytes)
            appendVarints(from: run, bytes: bytes, into: &values)
            return .values(values)
        case .values(var values):
            appendVarints(from: run, bytes: bytes, into: &values)
            return .values(values)
        }
    }

    private static func appendUnpackedElement(to field: MvtPackedField,
                                              value: UInt32,
                                              bytes: UnsafeRawBufferPointer) -> MvtPackedField {
        switch field {
        case .empty:
            return .values([value])
        case .range(let existing):
            var values = materialize(range: existing, bytes: bytes)
            values.append(value)
            return .values(values)
        case .values(var values):
            values.append(value)
            return .values(values)
        }
    }

    private static func materialize(range: Range<Int>, bytes: UnsafeRawBufferPointer) -> [UInt32] {
        var values: [UInt32] = []
        values.reserveCapacity(range.count)
        appendVarints(from: range, bytes: bytes, into: &values)
        return values
    }

    private static func appendVarints(from range: Range<Int>,
                                      bytes: UnsafeRawBufferPointer,
                                      into values: inout [UInt32]) {
        var reader = MvtVarintUInt32Reader(bytes: bytes, range: range)
        while let value = reader.next() {
            values.append(value)
        }
    }

    // MARK: - Wire primitives

    @inline(__always)
    private static func readVarint(_ bytes: UnsafeRawBufferPointer,
                                   _ offset: inout Int,
                                   end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < end {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) &<< shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 {
                throw MvtWireDecodeError.malformedVarint
            }
        }
        throw MvtWireDecodeError.truncatedVarint
    }

    private static func readLengthDelimited(_ bytes: UnsafeRawBufferPointer,
                                            _ offset: inout Int,
                                            end: Int) throws -> Range<Int> {
        let length = try readVarint(bytes, &offset, end: end)
        guard length <= UInt64(end - offset) else {
            throw MvtWireDecodeError.truncatedField
        }
        let start = offset
        offset += Int(length)
        return start..<offset
    }

    private static func readFixed32(_ bytes: UnsafeRawBufferPointer,
                                    _ offset: inout Int,
                                    end: Int) throws -> UInt32 {
        guard offset + 4 <= end else {
            throw MvtWireDecodeError.truncatedField
        }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4
        return UInt32(littleEndian: value)
    }

    private static func readFixed64(_ bytes: UnsafeRawBufferPointer,
                                    _ offset: inout Int,
                                    end: Int) throws -> UInt64 {
        guard offset + 8 <= end else {
            throw MvtWireDecodeError.truncatedField
        }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8
        return UInt64(littleEndian: value)
    }

    private static func decodeString(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    private static func decodeZigZag64(_ value: UInt64) -> Int64 {
        Int64(bitPattern: (value >> 1)) ^ -Int64(bitPattern: value & 1)
    }

    private static func skipField(_ bytes: UnsafeRawBufferPointer,
                                  _ offset: inout Int,
                                  end: Int,
                                  wireType: UInt64) throws {
        var groupDepth = 0
        var currentWireType = wireType

        while true {
            switch currentWireType {
            case 0:
                _ = try readVarint(bytes, &offset, end: end)
            case 1:
                guard offset + 8 <= end else { throw MvtWireDecodeError.truncatedField }
                offset += 8
            case 2:
                _ = try readLengthDelimited(bytes, &offset, end: end)
            case 3:
                groupDepth += 1
                guard groupDepth <= maximumGroupNestingDepth else {
                    throw MvtWireDecodeError.groupNestingTooDeep
                }
            case 4:
                groupDepth -= 1
                guard groupDepth >= 0 else {
                    throw MvtWireDecodeError.unmatchedGroupEnd
                }
            case 5:
                guard offset + 4 <= end else { throw MvtWireDecodeError.truncatedField }
                offset += 4
            default:
                throw MvtWireDecodeError.invalidWireType
            }

            guard groupDepth > 0 else {
                return
            }
            let tag = try readVarint(bytes, &offset, end: end)
            currentWireType = tag & 7
        }
    }
}
