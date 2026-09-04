// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// The Mapbox Vector Tile messages as plain values a test fills in and
/// serializes, so a fixture states a tile in terms of the schema (layers,
/// keys, values, features) and the bytes travel the real decoder.
///
/// `serializedData()` writes the protobuf wire format the way a conforming
/// encoder does: fields in field-number order, `repeated uint32` fields
/// packed, optional scalars written only when set, and an empty repeated
/// field omitted. The decoder under test never sees this code, so an
/// encode/decode round trip checks the two against the specification
/// rather than against each other.
package struct MvtTileMessage: Equatable {
    package var layers: [MvtLayerMessage] = []

    package init(layers: [MvtLayerMessage] = []) {
        self.layers = layers
    }

    package func serializedData() -> Data {
        var writer = MvtWireWriter()
        for layer in layers {
            writer.appendLengthDelimited(fieldNumber: 3, payload: layer.serializedData())
        }
        return writer.data
    }
}

package struct MvtLayerMessage: Equatable {
    /// The schema declares `version` required; a fixture that leaves the
    /// default gets the version the specification is written against.
    package var version: UInt32 = 2
    package var name: String = ""
    package var features: [MvtFeatureMessage] = []
    package var keys: [String] = []
    package var values: [MvtValue] = []
    /// Written only when set; the decoder's default is the schema's 4096.
    package var extent: UInt32?

    package init(version: UInt32 = 2,
         name: String = "",
         features: [MvtFeatureMessage] = [],
         keys: [String] = [],
         values: [MvtValue] = [],
         extent: UInt32? = nil) {
        self.version = version
        self.name = name
        self.features = features
        self.keys = keys
        self.values = values
        self.extent = extent
    }

    package func serializedData() -> Data {
        var writer = MvtWireWriter()
        writer.appendLengthDelimited(fieldNumber: 1, payload: Data(name.utf8))
        for feature in features {
            writer.appendLengthDelimited(fieldNumber: 2, payload: feature.serializedData())
        }
        for key in keys {
            writer.appendLengthDelimited(fieldNumber: 3, payload: Data(key.utf8))
        }
        for value in values {
            writer.appendLengthDelimited(fieldNumber: 4, payload: MvtValueMessage.serializedData(value))
        }
        if let extent {
            writer.appendVarint(fieldNumber: 5, value: UInt64(extent))
        }
        writer.appendVarint(fieldNumber: 15, value: UInt64(version))
        return writer.data
    }
}

package struct MvtFeatureMessage: Equatable {
    /// Written only when set, which is what `MvtDecodedFeature.hasID` reads.
    package var id: UInt64?
    package var tags: [UInt32] = []
    /// Written only when set; an unset type decodes as `.unknown`.
    package var type: MvtGeometryType?
    package var geometry: [UInt32] = []

    package init(id: UInt64? = nil,
         tags: [UInt32] = [],
         type: MvtGeometryType? = nil,
         geometry: [UInt32] = []) {
        self.id = id
        self.tags = tags
        self.type = type
        self.geometry = geometry
    }

    package func serializedData() -> Data {
        var writer = MvtWireWriter()
        if let id {
            writer.appendVarint(fieldNumber: 1, value: id)
        }
        writer.appendPackedVarints(fieldNumber: 2, values: tags)
        if let type {
            writer.appendVarint(fieldNumber: 3, value: UInt64(type.rawValue))
        }
        writer.appendPackedVarints(fieldNumber: 4, values: geometry)
        return writer.data
    }
}

/// The `Tile.Value` message: one field per value kind, and no field at all
/// for `.absent`.
package enum MvtValueMessage {
    package static func serializedData(_ value: MvtValue) -> Data {
        var writer = MvtWireWriter()
        switch value {
        case .string(let text):
            writer.appendLengthDelimited(fieldNumber: 1, payload: Data(text.utf8))
        case .float(let number):
            writer.appendFixed32(fieldNumber: 2, value: number.bitPattern)
        case .double(let number):
            writer.appendFixed64(fieldNumber: 3, value: number.bitPattern)
        case .int(let number):
            writer.appendVarint(fieldNumber: 4, value: UInt64(bitPattern: number))
        case .uint(let number):
            writer.appendVarint(fieldNumber: 5, value: number)
        case .sint(let number):
            writer.appendVarint(fieldNumber: 6, value: zigZag(number))
        case .bool(let flag):
            writer.appendVarint(fieldNumber: 7, value: flag ? 1 : 0)
        case .absent:
            break
        }
        return writer.data
    }

    private static func zigZag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }
}

/// Protobuf wire primitives: varints, the two fixed widths, and
/// length-delimited fields, each tagged with its field number and wire type.
package struct MvtWireWriter {
    package private(set) var data = Data()

    package init() {}

    package mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    package mutating func appendTag(fieldNumber: UInt64, wireType: UInt64) {
        appendVarint((fieldNumber << 3) | wireType)
    }

    package mutating func appendVarint(fieldNumber: UInt64, value: UInt64) {
        appendTag(fieldNumber: fieldNumber, wireType: 0)
        appendVarint(value)
    }

    package mutating func appendFixed32(fieldNumber: UInt64, value: UInt32) {
        appendTag(fieldNumber: fieldNumber, wireType: 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    package mutating func appendFixed64(fieldNumber: UInt64, value: UInt64) {
        appendTag(fieldNumber: fieldNumber, wireType: 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    package mutating func appendLengthDelimited(fieldNumber: UInt64, payload: Data) {
        appendTag(fieldNumber: fieldNumber, wireType: 2)
        appendVarint(UInt64(payload.count))
        data.append(payload)
    }

    /// One packed run holding every value; nothing at all for an empty list,
    /// which is how an encoder writes an empty repeated field.
    package mutating func appendPackedVarints(fieldNumber: UInt64, values: [UInt32]) {
        guard values.isEmpty == false else { return }
        var payload = MvtWireWriter()
        for value in values {
            payload.appendVarint(UInt64(value))
        }
        appendLengthDelimited(fieldNumber: fieldNumber, payload: payload.data)
    }
}
