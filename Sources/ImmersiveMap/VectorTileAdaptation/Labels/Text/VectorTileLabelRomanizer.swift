// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Writes a local name in Latin letters for a map whose language is written
/// in them, so a street that has no spelling in the map's language reads
/// "Georgiyevskiy Lane" instead of "Георгиевский переулок" and the map shows
/// one alphabet.
///
/// The system's ICU transliterators do the work: Cyrillic through the BGN
/// romanization (the one maps use), Greek, Armenian and Georgian through the
/// generic one, then folded to plain ASCII, with the soft and hard signs
/// dropped rather than written as apostrophes. Only the words in those
/// scripts are touched: a Latin part of the name (a route number, a brand)
/// keeps its spelling and punctuation. A name with a letter of any other
/// script is declined, because the generic transliterator reads Japanese
/// kanji as Mandarin and drops the vowels of Arabic, and a wrong spelling is
/// worse than the local one.
///
/// For an English map a trailing or leading Russian street type is also
/// translated and moved to the end, the way English names streets:
/// "улица Щепкина" becomes "Shchepkina Street". Only a lowercase type word
/// counts, so a capitalized one that is part of a proper name, like the
/// metro station "Площадь Революции", stays transliterated.
struct VectorTileLabelRomanizer: Equatable {
    /// False when the map's language is not written in Latin letters:
    /// nothing is romanized then.
    let isEnabled: Bool
    private let translatesRussianStreetTypes: Bool

    init(targetLanguage: ImmersiveMapSettings.LabelLanguage) {
        let language = Locale.Language(identifier: targetLanguage.code)
        self.isEnabled = language.script == .latin
        self.translatesRussianStreetTypes = language.languageCode == .english
    }

    /// The name in ASCII Latin letters, or nil when there is nothing to
    /// romanize (the name is already Latin) or the name carries a script
    /// this does not handle.
    func romanize(_ name: String) -> String? {
        guard isEnabled else { return nil }

        var hasRomanizableLetter = false
        for scalar in name.unicodeScalars {
            switch Self.script(of: scalar) {
            case .romanizable:
                hasRomanizableLetter = true
            case .unsupported:
                return nil
            case .latin, .other:
                continue
            }
        }
        guard hasRomanizableLetter else { return nil }

        var words = Self.words(of: name)
        var trailingType: String?
        if translatesRussianStreetTypes {
            trailingType = Self.extractRussianStreetType(from: &words)
        }

        var result = words.map { word in
            word.isRomanizable ? Self.transliterate(word.text) : word.text
        }.joined()
        if let trailingType {
            result = result.trimmingCharacters(in: .whitespaces) + " " + trailingType
        }
        return result
    }

    // MARK: - Words

    private struct Word {
        var text: String
        /// A run of letters of a script this romanizes, as opposed to the
        /// text between such runs (spaces, punctuation, digits, Latin).
        let isRomanizable: Bool
    }

    /// The name split into the runs of romanizable letters and the text
    /// between them. A run is one word of the source, so the transliterator
    /// sees word starts where the name has them (BGN writes a leading "е"
    /// as "ye").
    private static func words(of name: String) -> [Word] {
        var words: [Word] = []
        for character in name {
            let isRomanizable = character.unicodeScalars.first.map { script(of: $0) == .romanizable } ?? false
            if let last = words.last, last.isRomanizable == isRomanizable {
                words[words.count - 1].text.append(character)
            } else {
                words.append(Word(text: String(character), isRomanizable: isRomanizable))
            }
        }
        return words
    }

    private static let transform = StringTransform("Russian-Latin/BGN; Any-Latin; Latin-ASCII")

    /// One word in ASCII. The soft and hard signs come out of the ASCII fold
    /// as `'` and `"` and are dropped ("Bolshoy", not "Bol'shoy"). A Georgian
    /// word starts with a capital: the script writes names without one
    /// (Unicode counts its everyday letters as lowercase), Latin does not.
    private static func transliterate(_ word: String) -> String {
        guard var latin = word.applyingTransform(transform, reverse: false) else { return word }
        latin.removeAll { $0 == "'" || $0 == "\"" }
        if let first = word.unicodeScalars.first, isGeorgian(first) {
            latin = latin.prefix(1).uppercased() + latin.dropFirst()
        }
        return latin
    }

    private static func isGeorgian(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F: true
        default: false
        }
    }

    // MARK: - Russian street types

    /// The English words for the Russian street types, keyed by the
    /// lowercase Russian word.
    private static let russianStreetTypes: [String: String] = [
        "улица": "Street",
        "переулок": "Lane",
        "проспект": "Avenue",
        "площадь": "Square",
        "бульвар": "Boulevard",
        "шоссе": "Highway",
        "набережная": "Embankment",
        "проезд": "Passage",
        "аллея": "Alley",
        "мост": "Bridge",
        "тупик": "Dead End",
    ]

    /// Removes a lowercase Russian street type standing as the first or the
    /// last word of a name with at least one other word, and returns its
    /// English word. Nil, and the words untouched, when the name has none.
    private static func extractRussianStreetType(from words: inout [Word]) -> String? {
        let letterRuns = words.indices.filter { words[$0].isRomanizable }
        guard letterRuns.count >= 2 else { return nil }

        for index in [letterRuns[letterRuns.count - 1], letterRuns[0]] {
            guard let english = russianStreetTypes[words[index].text] else { continue }
            words.remove(at: index)
            // The space that separated the type from the rest goes with it.
            if index < words.count, words[index].isRomanizable == false,
               words[index].text.allSatisfy(\.isWhitespace) {
                words.remove(at: index)
            } else if index > 0, words[index - 1].isRomanizable == false,
                      words[index - 1].text.allSatisfy(\.isWhitespace) {
                words.remove(at: index - 1)
            }
            return english
        }
        return nil
    }

    // MARK: - Scripts

    private enum Script {
        case latin
        /// Cyrillic, Greek, Armenian and Georgian.
        case romanizable
        /// A letter of any other script.
        case unsupported
        /// Not a letter: digits, punctuation, spaces, combining marks.
        case other
    }

    private static func script(of scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F,  // Cyrillic
             0x0370...0x03FF, 0x1F00...0x1FFF,                                   // Greek
             0x0530...0x058F, 0xFB13...0xFB17,                                   // Armenian
             0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F:                  // Georgian
            return scalar.properties.isAlphabetic ? .romanizable : .other
        case 0x0000...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF:
            return scalar.properties.isAlphabetic ? .latin : .other
        default:
            return scalar.properties.isAlphabetic ? .unsupported : .other
        }
    }
}
