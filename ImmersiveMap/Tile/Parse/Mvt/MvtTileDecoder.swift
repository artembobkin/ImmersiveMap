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
    /// The layer message misses a field the schema declares `required`
    /// (version or name), which a conforming protobuf decoder rejects.
    case missingRequiredLayerField
}

/// Hand-written decoder for the Mapbox Vector Tile protobuf schema
/// (`vector_tile.proto`, version 2.1). It is the only protobuf code in the
/// package: the schema has four messages and seven value kinds, and reading
/// them straight off the wire is what a general protobuf runtime cannot do.
///
/// A generic decoder materializes every feature's `tags` and `geometry` as
/// fresh `[UInt32]` arrays; on a dense city tile that is thousands of
/// short-lived allocations per parse, thrown away right after the geometry
/// pass converts them again. This decoder walks the wire format once via
/// `withUnsafeBytes` and leaves packed fields as byte ranges into the
/// payload; `MvtGeometryDecoder` then decodes rings straight from those
/// bytes.
///
/// Wire-format behaviour follows the protobuf encoding rules: packed and
/// unpacked repeated encodings, split packed runs concatenated, scalars
/// last-one-wins, unknown fields (including nested groups) skipped, truncated
/// or malformed input throws, and a layer without the required
/// `version`/`name` throws. Three deliberate leniencies: invalid UTF-8 in
/// strings decodes with replacement characters instead of failing the whole
/// tile; a malformed varint inside a packed tags/geometry run surfaces later
/// as a short read that drops the affected feature's geometry or trailing
/// tags instead of failing the whole tile; and a `Value` message that sets
/// more than one of its fields (which the specification forbids) keeps the
/// last one in wire order.
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
                appendPackedRun(to: &feature.tags, run: packedRange, bytes: bytes)
            case (2, 0):
                let value = UInt32(truncatingIfNeeded: try readVarint(bytes, &offset, end: end))
                appendUnpackedElement(to: &feature.tags, value: value, bytes: bytes)
            case (3, 0):
                let rawType = Int(truncatingIfNeeded: try readVarint(bytes, &offset, end: end))
                // proto2 keeps unrecognized enum values out of the field, so
                // an invalid geometry type leaves the previous value alone.
                if let geomType = MvtGeometryType(rawValue: rawType) {
                    feature.type = geomType
                }
            case (4, lengthDelimitedWireType):
                let packedRange = try readLengthDelimited(bytes, &offset, end: end)
                appendPackedRun(to: &feature.geometry, run: packedRange, bytes: bytes)
            case (4, 0):
                let value = UInt32(truncatingIfNeeded: try readVarint(bytes, &offset, end: end))
                appendUnpackedElement(to: &feature.geometry, value: value, bytes: bytes)
            default:
                try skipField(bytes, &offset, end: end, wireType: wireType)
            }
        }

        return feature
    }

    private static func decodeValue(bytes: UnsafeRawBufferPointer, range: Range<Int>) throws -> MvtValue {
        var value: MvtValue = .absent
        var offset = range.lowerBound
        let end = range.upperBound

        while offset < end {
            let tag = try readVarint(bytes, &offset, end: end)
            let fieldNumber = tag >> 3
            let wireType = tag & 7

            switch (fieldNumber, wireType) {
            case (1, lengthDelimitedWireType):
                let stringRange = try readLengthDelimited(bytes, &offset, end: end)
                value = .string(decodeString(bytes, range: stringRange))
            case (2, 5):
                value = .float(Float(bitPattern: try readFixed32(bytes, &offset, end: end)))
            case (3, 1):
                value = .double(Double(bitPattern: try readFixed64(bytes, &offset, end: end)))
            case (4, 0):
                value = .int(Int64(bitPattern: try readVarint(bytes, &offset, end: end)))
            case (5, 0):
                value = .uint(try readVarint(bytes, &offset, end: end))
            case (6, 0):
                value = .sint(decodeZigZag64(try readVarint(bytes, &offset, end: end)))
            case (7, 0):
                value = .bool(try readVarint(bytes, &offset, end: end) != 0)
            default:
                try skipField(bytes, &offset, end: end, wireType: wireType)
            }
        }

        return value
    }

    // MARK: - Packed field accumulation

    /// The first packed run stays a byte range; a second run (or a mix with
    /// unpacked elements) falls back to materializing, which the wire format
    /// requires treating as one concatenated field. In the `.values` cases the
    /// field is cleared before mutating so the array binding is uniquely
    /// referenced; otherwise every append would copy the whole array and an
    /// element-by-element unpacked encoding would decode quadratically.
    private static func appendPackedRun(to field: inout MvtPackedField,
                                        run: Range<Int>,
                                        bytes: UnsafeRawBufferPointer) {
        switch field {
        case .empty:
            field = .range(run)
        case .range(let existing):
            var values = materialize(range: existing, bytes: bytes)
            appendVarints(from: run, bytes: bytes, into: &values)
            field = .values(values)
        case .values(var values):
            field = .empty
            appendVarints(from: run, bytes: bytes, into: &values)
            field = .values(values)
        }
    }

    private static func appendUnpackedElement(to field: inout MvtPackedField,
                                              value: UInt32,
                                              bytes: UnsafeRawBufferPointer) {
        switch field {
        case .empty:
            field = .values([value])
        case .range(let existing):
            var values = materialize(range: existing, bytes: bytes)
            values.append(value)
            field = .values(values)
        case .values(var values):
            field = .empty
            values.append(value)
            field = .values(values)
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
