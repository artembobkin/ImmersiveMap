// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The alphabets the label text logic tells apart: Latin, and the ones the
/// romanizer handles (`VectorTileLabelRomanizer`). A letter of any other
/// script is `other`.
enum VectorTileLabelScript: Equatable {
    case latin
    case cyrillic
    case greek
    case armenian
    case georgian
    case other

    /// The script a language is written in, nil when it is none of the
    /// ones told apart here (Japanese, Arabic and the rest).
    init?(language: ImmersiveMapSettings.LabelLanguage) {
        switch Locale.Language(identifier: language.code).script?.identifier {
        case "Latn": self = .latin
        case "Cyrl": self = .cyrillic
        case "Grek": self = .greek
        case "Armn": self = .armenian
        case "Geor": self = .georgian
        default: return nil
        }
    }

    /// The script of a letter, nil for anything that is not one: digits,
    /// punctuation, spaces, combining marks.
    static func of(_ scalar: Unicode.Scalar) -> VectorTileLabelScript? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0530...0x058F, 0xFB13...0xFB17:
            return .armenian
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F:
            return .georgian
        case 0x0000...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF:
            return .latin
        default:
            return .other
        }
    }

    /// Whether `text` is written in this script: it has a letter, and every
    /// letter is of this script. A Latin part (a route number, a brand)
    /// makes it mixed, which is not.
    func writes(_ text: String) -> Bool {
        var hasLetter = false
        for scalar in text.unicodeScalars {
            guard let script = Self.of(scalar) else { continue }
            guard script == self else { return false }
            hasLetter = true
        }
        return hasLetter
    }
}
