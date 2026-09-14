// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

/// A feature's properties as the tile carries them, read through typed
/// accessors: a schema is loose about types (an id may be a number or its
/// digits, a height a number or "12 ft", a flag a bool or the word "yes").
public struct ImmersiveMapFeatureProperties {
    let values: [String: MvtValue]

    init(values: [String: MvtValue]) {
        self.values = values
    }

    /// The property as text: `nil` when the key is absent, and the empty
    /// string when the key is present with a non-string value (the reading
    /// this accessor has always given, kept so a style written against it
    /// keeps working).
    public func string(_ key: String) -> String? {
        guard let value = values[key] else {
            return nil
        }
        return value.stringValue ?? ""
    }

    public func double(_ key: String) -> Double? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .double(let number):
            return number
        case .float(let number):
            return Double(number)
        case .int(let number), .sint(let number):
            return Double(number)
        case .uint(let number):
            return Double(number)
        case .string(let text):
            return Double(text)
        case .bool, .absent:
            return nil
        }
    }

    public func integer(_ key: String) -> Int? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .int(let number), .sint(let number):
            return Int(number)
        case .uint(let number):
            return Int(number)
        case .double(let number):
            return Int(number)
        case .float(let number):
            return Int(number)
        case .string(let text):
            return Int(text)
        case .bool, .absent:
            return nil
        }
    }

    /// The property as a measure in metres: a number as it is, a string by
    /// its leading number (`"12"`, `"12.5 m"`, `"3;4"` reads 3), feet
    /// converted. Nil when the key is absent or carries no number.
    public func metres(_ key: String) -> Float? {
        values[key]?.metresValue
    }

    /// The property as an identifier: a non-negative integer, or a string
    /// that spells one.
    public func unsignedInteger(_ key: String) -> UInt64? {
        values[key]?.uint64Value
    }

    /// The property spelled as text, whatever its type: a string as it is, a
    /// number as its digits, a flag as `1` or `0`, and empty when the key is
    /// absent. For keys that make up an identity.
    public func text(_ key: String) -> String {
        switch values[key] {
        case .string(let text): return text
        case .int(let number), .sint(let number): return String(number)
        case .uint(let number): return String(number)
        case .double(let number): return String(number)
        case .float(let number): return String(number)
        case .bool(let flag): return flag ? "1" : "0"
        case .absent, nil: return ""
        }
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = values[key] else {
            return nil
        }
        if case .bool(let flag) = value {
            return flag
        }
        if let integer = integer(key) {
            return integer != 0
        }
        if case .string(let text) = value {
            let normalized = text.lowercased()
            if normalized == "true" || normalized == "yes" || normalized == "1" {
                return true
            }
            if normalized == "false" || normalized == "no" || normalized == "0" {
                return false
            }
        }
        return nil
    }
}
