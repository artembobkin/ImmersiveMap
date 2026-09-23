// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// What a feature is called, as the schema reading states it: its name in
/// the local language and by language code.
/// The engine picks the spelling the map's language asks for from these
/// and never reads a name field itself.
public struct ImmersiveMapLabelFacts: Equatable, Sendable {
    /// The name in the local language, nil when the source states none.
    public var name: String?
    /// The name by language code (`"en"`, `"ru"`, ...), where the source
    /// states one.
    public var namesByLanguage: [String: String]
    /// The feature names a body of water. The parser adds ocean and sea
    /// names of its own at the coarse zooms and skips any the tile already
    /// labels; this is how it recognises those.
    public var namesWaterBody: Bool

    public init(name: String? = nil,
                namesByLanguage: [String: String] = [:],
                namesWaterBody: Bool = false) {
        self.name = name
        self.namesByLanguage = namesByLanguage
        self.namesWaterBody = namesWaterBody
    }
}
