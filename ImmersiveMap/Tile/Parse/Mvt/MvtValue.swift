// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// One entry of a layer's value table: the typed property value the Mapbox
/// Vector Tile `Tile.Value` message carries. The specification has a
/// well-formed value set exactly one of the seven fields; `.absent` is a
/// `Value` message that sets none of them, which the wire format permits.
///
/// Feature attributes are dictionaries of these, keyed by the layer's key
/// table (`TileMvtParser.decodeAttributes`).
enum MvtValue: Hashable, Sendable {
    case string(String)
    case float(Float)
    case double(Double)
    case int(Int64)
    case uint(UInt64)
    case sint(Int64)
    case bool(Bool)
    case absent

    /// The payload when the value is a string, `nil` for every other kind.
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var floatValue: Float? {
        if case .float(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    var uintValue: UInt64? {
        if case .uint(let value) = self { return value }
        return nil
    }

    var sintValue: Int64? {
        if case .sint(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The value read as an integer whatever numeric field the writer chose.
    /// Planetiler writes every whole number as `sint` (a negative `layer`, a
    /// `street` id), other writers use `int` or `uint`, and hand-written
    /// tiles sometimes ship numbers as strings; a reader that matches one
    /// case reads zero for the rest, which is how a tunnel's `layer=-1`
    /// once went unread.
    var integerValue: Int? {
        switch self {
        case .int(let number), .sint(let number):
            return Int(number)
        case .uint(let number):
            guard number <= UInt64(Int.max) else { return nil }
            return Int(number)
        case .float(let number):
            return Int(number)
        case .double(let number):
            return Int(number)
        case .string(let text):
            return Int(text)
        case .bool, .absent:
            return nil
        }
    }
}

/// The `Tile.GeomType` enumeration of the Mapbox Vector Tile schema, with the
/// specification's raw values.
enum MvtGeometryType: Int, Hashable, Sendable {
    case unknown = 0
    case point = 1
    case linestring = 2
    case polygon = 3
}
