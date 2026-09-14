// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What a feature is called, as the schema reading states it: its name in
/// the local language and by language code, or the house number it is.
/// The engine picks the spelling the map's language asks for from these
/// and never reads a name field itself.
public struct ImmersiveMapLabelFacts: Equatable, Sendable {
    /// The name in the local language, nil when the source states none.
    public var name: String?
    /// The name by language code (`"en"`, `"ru"`, ...), where the source
    /// states one.
    public var namesByLanguage: [String: String]
    /// The house number, for a feature that is a house number rather than
    /// a named thing. A label with a house number shows the number.
    public var houseNumber: String?
    /// The feature names a body of water. The parser adds ocean and sea
    /// names of its own at the coarse zooms and skips any the tile already
    /// labels; this is how it recognises those.
    public var namesWaterBody: Bool

    public init(name: String? = nil,
                namesByLanguage: [String: String] = [:],
                houseNumber: String? = nil,
                namesWaterBody: Bool = false) {
        self.name = name
        self.namesByLanguage = namesByLanguage
        self.houseNumber = houseNumber
        self.namesWaterBody = namesWaterBody
    }

    /// The reading of the OpenStreetMap name tags: `name` for the local
    /// name, and `name:xx` or `name_xx` (OpenMapTiles flattens the colon)
    /// for the name in language `xx`. Nil for a feature that carries no
    /// name at all.
    public static func openStreetMap(_ properties: ImmersiveMapFeatureProperties) -> ImmersiveMapLabelFacts? {
        var name: String?
        var namesByLanguage: [String: String] = [:]
        for (key, value) in properties.values {
            guard key.hasPrefix("name"), let text = value.stringValue, text.isEmpty == false else {
                continue
            }
            if key.count == 4 {
                name = text
            } else if key.count > 5 {
                let separator = key[key.index(key.startIndex, offsetBy: 4)]
                guard separator == ":" || separator == "_" else { continue }
                let code = String(key.dropFirst(5))
                if namesByLanguage[code] == nil {
                    namesByLanguage[code] = text
                }
            }
        }
        guard name != nil || namesByLanguage.isEmpty == false else {
            return nil
        }
        return ImmersiveMapLabelFacts(name: name, namesByLanguage: namesByLanguage)
    }
}
