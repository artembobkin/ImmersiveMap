// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct VectorTileLabelTextResolver {
    private let glyphCoverage: VectorTileLabelGlyphCoverage

    init(glyphCoverage: VectorTileLabelGlyphCoverage) {
        self.glyphCoverage = glyphCoverage
    }

    func resolveText(properties: [String: VectorTile_Tile.Value],
                     preferences: VectorTileLabelLanguagePreferences,
                     additionalKeys: [String] = []) -> String? {
        var resolvedKeys = Set<String>()
        for candidate in preferences.fallbackChain {
            resolvedKeys.insert(candidate.fieldName)
            guard let text = properties[candidate.fieldName]?.stringValue,
                  text.isEmpty == false,
                  glyphCoverage.canRender(text) else {
                continue
            }

            return text
        }

        for key in additionalKeys where resolvedKeys.insert(key).inserted {
            guard let text = properties[key]?.stringValue,
                  text.isEmpty == false,
                  glyphCoverage.canRender(text) else {
                continue
            }

            return text
        }

        return nil
    }

    func resolveHouseNumber(properties: [String: VectorTile_Tile.Value],
                            additionalKeys: [String] = []) -> String? {
        for key in ["house_num"] + additionalKeys {
            guard let text = properties[key]?.stringValue,
                  text.isEmpty == false,
                  glyphCoverage.canRender(text) else {
                continue
            }
            return text
        }
        return nil
    }
}
