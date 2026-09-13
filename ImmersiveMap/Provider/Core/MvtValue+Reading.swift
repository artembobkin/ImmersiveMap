// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// The readings behind `ImmersiveMapFeatureProperties`: the decoder hands
/// over a value as the tile typed it, and a schema is loose about types (an
/// id may be a number or its digits, a height a number or "12 ft").
extension MvtValue {
    /// The value as an identifier: a non-negative integer, or a string that
    /// spells one.
    var uint64Value: UInt64? {
        switch self {
        case .uint(let number):
            return number
        case .sint(let number), .int(let number):
            return number >= 0 ? UInt64(number) : nil
        case .string(let text):
            return UInt64(text)
        case .float, .double, .bool, .absent:
            return nil
        }
    }

    /// The value as a measure in metres: a number as it is, a string by its
    /// leading number (`"12"`, `"12.5 m"`, `"3;4"` reads 3), feet converted.
    var metresValue: Float? {
        switch self {
        case .float(let number):
            return number
        case .double(let number):
            return Float(number)
        case .uint(let number):
            return Float(number)
        case .int(let number), .sint(let number):
            return Float(number)
        case .bool, .absent:
            return nil
        case .string(let text):
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let token = raw.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).first
            guard let token else { return nil }
            var numeric = ""
            var hasDigit = false
            for scalar in token.unicodeScalars {
                let ch = Character(scalar)
                if ch.isNumber {
                    numeric.append(ch)
                    hasDigit = true
                    continue
                }
                if (ch == "-" || ch == "+"), numeric.isEmpty {
                    numeric.append(ch)
                    continue
                }
                if ch == ".", numeric.contains(".") == false {
                    numeric.append(ch)
                    continue
                }
                break
            }
            guard hasDigit, let value = Float(numeric) else { return nil }
            if raw.contains("ft") || raw.contains("feet") {
                return value * 0.3048
            }
            return value
        }
    }
}
