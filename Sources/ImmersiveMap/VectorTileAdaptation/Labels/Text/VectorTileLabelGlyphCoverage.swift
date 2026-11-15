// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

struct VectorTileLabelGlyphCoverage {
    static let legacyAtlasForTests = VectorTileLabelGlyphCoverage(
        supportedScalars: Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-=[]{}|;:'\\\",./<>?"
            .unicodeScalars
            .map(\.value))
            .union(Set(UInt32(0x0400)...UInt32(0x04FF)))
    )

    private let supportedScalars: Set<UInt32>

    init(supportedScalars: Set<UInt32>) {
        self.supportedScalars = supportedScalars
    }

    init(atlasData: AtlasData, thinAtlasData: AtlasData) {
        self.supportedScalars = Set((atlasData.glyphs + thinAtlasData.glyphs).map(\.unicode))
    }

    func canRender(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            supportedScalars.contains($0.value) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
