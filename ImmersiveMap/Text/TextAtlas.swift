// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// One of the two bundled MSDF glyph atlases. The layout side reads the metrics
/// JSON and the render side reads the PNG of the same name, so the resource name
/// is declared once here.
enum TextAtlasResource: String {
    case bold = "atlas"
    case thin = "atlas_thin"
}

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

extension AtlasData {
    /// Empty atlas used when the bundled metrics cannot be read: every string
    /// then measures to zero instead of taking the whole package down.
    static let fallback = AtlasData(
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

    /// Decodes the bundled metrics for one atlas.
    /// - Returns: `nil` when the resource is missing or cannot be decoded.
    static func bundled(_ resource: TextAtlasResource, in bundle: Bundle = .module) -> AtlasData? {
        guard let url = bundle.url(forResource: resource.rawValue, withExtension: "json") else {
            #if DEBUG
            print("Could not find atlas JSON in bundle: \(resource.rawValue).json")
            #endif
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AtlasData.self, from: data)
        } catch {
            #if DEBUG
            print("Failed to decode atlas JSON \(resource.rawValue).json: \(error)")
            #endif
            return nil
        }
    }

    /// Unicode scalar to glyph, built once so layout does not scan the glyph
    /// array for every character it measures.
    func makeGlyphLookupTable() -> [UInt32: Glyph] {
        var lookup: [UInt32: Glyph] = [:]
        lookup.reserveCapacity(glyphs.count)
        for glyph in glyphs {
            lookup[glyph.unicode] = glyph
        }
        return lookup
    }
}
