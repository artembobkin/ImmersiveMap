// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation

struct AtlasData: Codable {
    let atlas: AtlasInfo
    let metrics: Metrics
    let glyphs: [Glyph]
}

struct AtlasInfo: Codable {
    let type: String
    let distanceRange: CGFloat
    let distanceRangeMiddle: CGFloat
    let size: CGFloat
    let width: Int
    let height: Int
    let yOrigin: String
}

struct Metrics: Codable {
    let emSize: CGFloat
    let lineHeight: CGFloat
    let ascender: CGFloat
    let descender: CGFloat
    let underlineY: CGFloat
    let underlineThickness: CGFloat
}

struct Glyph: Codable {
    let unicode: UInt32
    let advance: CGFloat
    var planeBounds: Bounds?
    var atlasBounds: Bounds?
    
    enum CodingKeys: String, CodingKey {
        case unicode, advance, planeBounds = "planeBounds", atlasBounds = "atlasBounds"
    }
}

struct Bounds: Codable {
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat
    let top: CGFloat
}

/// The glyph metrics of the two text atlases, the bold and the thin: what
/// the atlas JSON states about each glyph, and the tables that find a glyph
/// by its scalar. Data alone, read from the resource bundle with no GPU, so
/// the text layout (`TextLayout`) works wherever a tile is parsed or a test
/// runs. The pixels the metrics describe are `TextAtlas`'s.
final class GlyphAtlasMetrics: Sendable {
    static let boldAtlasName = "atlas"
    static let thinAtlasName = "atlas_thin"

    let bold: AtlasData
    let thin: AtlasData
    let boldGlyphLookup: [UInt32: Glyph]
    let thinGlyphLookup: [UInt32: Glyph]

    /// `bundle` holds the atlases (`ImmersiveMapResourceBundle`). A missing
    /// bold atlas leaves an empty one, a missing thin atlas the bold one.
    init(bundle: Bundle) {
        let bold = Self.load(named: Self.boldAtlasName, bundle: bundle) ?? Self.makeFallbackAtlasData()
        let thin = Self.load(named: Self.thinAtlasName, bundle: bundle) ?? bold
        self.bold = bold
        self.thin = thin
        self.boldGlyphLookup = Self.makeGlyphLookupTable(from: bold.glyphs)
        self.thinGlyphLookup = Self.makeGlyphLookupTable(from: thin.glyphs)
    }

    func atlasData(for weight: LabelFontWeight) -> AtlasData {
        switch weight {
        case .bold:
            return bold
        case .thin:
            return thin
        }
    }

    func glyphLookup(for weight: LabelFontWeight) -> [UInt32: Glyph] {
        switch weight {
        case .bold:
            return boldGlyphLookup
        case .thin:
            return thinGlyphLookup
        }
    }

    /// Atlas texels per em of a weight's atlas: what a width stated in ems
    /// spans in the distance field.
    func atlasEmTexels(for weight: LabelFontWeight) -> CGFloat {
        atlasData(for: weight).atlas.size
    }

    var glyphCoverage: VectorTileLabelGlyphCoverage {
        VectorTileLabelGlyphCoverage(atlasData: bold, thinAtlasData: thin)
    }

    static func makeGlyphLookupTable(from glyphs: [Glyph]) -> [UInt32: Glyph] {
        var lookup: [UInt32: Glyph] = [:]
        lookup.reserveCapacity(glyphs.count)
        for glyph in glyphs {
            lookup[glyph.unicode] = glyph
        }
        return lookup
    }

    private static func load(named name: String, bundle: Bundle) -> AtlasData? {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            #if DEBUG
            print("Could not find atlas JSON in bundle: \(name).json")
            #endif
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let atlas = try JSONDecoder().decode(AtlasData.self, from: data)
            return atlas
        } catch {
            #if DEBUG
            print("Failed to decode atlas JSON \(name).json: \(error)")
            #endif
            return nil
        }
    }

    private static func makeFallbackAtlasData() -> AtlasData {
        return AtlasData(
            atlas: AtlasInfo(type: "fallback",
                             distanceRange: 0,
                             distanceRangeMiddle: 0,
                             size: 1,
                             width: 1,
                             height: 1,
                             yOrigin: "bottom"),
            metrics: Metrics(emSize: 1,
                             lineHeight: 1,
                             ascender: 0,
                             descender: 0,
                             underlineY: 0,
                             underlineThickness: 0),
            glyphs: []
        )
    }
}
