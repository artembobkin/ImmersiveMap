// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The texts of the tile grid: what is written inside a tile, how large,
/// and the glyphs of it as the GPU takes them. A text is laid out once by
/// the engine's text layout (`TextLayout`, handed in as a closure so
/// this is testable without Metal) and kept, so a frame that moves the
/// camera only places glyphs it already has.
final class TileGridLabels {
    /// A text laid out round its own middle, in ems.
    struct Layout {
        let widthEm: Float
        let heightEm: Float
        /// The glyphs' corners, six to a glyph: where each stands from the
        /// text's middle (x right, y up) and its place in the atlas.
        let corners: [(offsetEm: SIMD2<Float>, atlasUV: SIMD2<Float>)]
    }

    /// What decides the texts of a frame besides its tiles.
    struct Key: Equatable {
        let format: ImmersiveMapSettings.TileGridSettings.LabelFormat
        let labelRevision: UInt64
    }

    /// The layouts and the texts kept at most, each: past it they are let
    /// go and made again as the frames ask.
    private static let cacheLimit = 4096

    private let layOut: (String) -> TextMetrics
    private var layouts: [String: Layout] = [:]
    private var texts: [Tile: String?] = [:]
    private var key: Key?

    /// `layOut`: a text's glyphs at one em to the unit, their box's
    /// south-west corner at the origin (`TextLayout.collectLabelVertices`
    /// at scale 1).
    init(layOut: @escaping (String) -> TextMetrics) {
        self.layOut = layOut
    }

    /// What is written inside a tile: the app's own text when it gives a
    /// provider, the tile's numbers in the settings' format otherwise, nil
    /// for no text.
    static func text(for tile: Tile,
                     format: ImmersiveMapSettings.TileGridSettings.LabelFormat,
                     provider: ((ImmersiveMapTileID) -> String?)?) -> String? {
        if let provider {
            let text = provider(ImmersiveMapTileID(tile))
            return text?.isEmpty == false ? text : nil
        }
        switch format {
        case .zxy: return "\(tile.z)/\(tile.x)/\(tile.y)"
        case .xyz: return "\(tile.x)/\(tile.y)/\(tile.z)"
        case .hidden: return nil
        }
    }

    /// The share of a tile's side one em of a text takes, the largest at
    /// which the text keeps within its shares of the tile's width and
    /// height. Zero for a text with no extent.
    static func tileSharePerEm(widthEm: Float, heightEm: Float, widthShare: Float, heightShare: Float) -> Float {
        guard widthEm > 0, heightEm > 0 else { return 0 }
        return max(min(widthShare / widthEm, heightShare / heightEm), 0)
    }

    /// The glyphs of the texts of `tiles`, each tile's text in its middle,
    /// `tiles[index]` being the tile `tileIndex` names.
    /// `minimumTilePx`: the narrowest a tile that shows its text is on
    /// screen, in pixels.
    func glyphs(for tiles: [VisibleTile],
                settings: ImmersiveMapSettings.TileGridSettings,
                content: TileGridContent,
                minimumTilePx: Float) -> [TileGridGlyphGPU] {
        let key = Key(format: settings.labelFormat, labelRevision: content.labelRevision)
        if key != self.key || texts.count > Self.cacheLimit {
            texts.removeAll(keepingCapacity: true)
            self.key = key
        }
        if layouts.count > Self.cacheLimit {
            layouts.removeAll(keepingCapacity: true)
        }

        var glyphs: [TileGridGlyphGPU] = []
        for (index, visible) in tiles.enumerated() {
            let text: String?
            if let known = texts[visible.tile] {
                text = known
            } else {
                text = Self.text(for: visible.tile, format: settings.labelFormat, provider: content.labelProvider)
                texts[visible.tile] = .some(text)
            }
            guard let text, let layout = layout(of: text) else { continue }
            let share = Self.tileSharePerEm(widthEm: layout.widthEm,
                                            heightEm: layout.heightEm,
                                            widthShare: settings.labelMaximumWidthShare,
                                            heightShare: settings.labelMaximumHeightShare)
            guard share > 0 else { continue }
            let minimumEmPx = minimumTilePx * share
            for corner in layout.corners {
                // The text's y grows up and the tile's v grows south.
                let tileUV = SIMD2<Float>(0.5 + corner.offsetEm.x * share, 0.5 - corner.offsetEm.y * share)
                glyphs.append(TileGridGlyphGPU(tileUV: tileUV,
                                               atlasUV: corner.atlasUV,
                                               tileIndex: UInt32(index),
                                               minimumEmPx: minimumEmPx))
            }
        }
        return glyphs
    }

    private func layout(of text: String) -> Layout? {
        if let layout = layouts[text] { return layout }
        let metrics = layOut(text)
        guard metrics.vertices.isEmpty == false, metrics.size.width > 0, metrics.size.height > 0 else { return nil }
        let middle = SIMD2<Float>(metrics.size.width, metrics.size.height) * 0.5
        let layout = Layout(widthEm: metrics.size.width,
                            heightEm: metrics.size.height,
                            corners: metrics.vertices.map { ($0.position - middle, $0.uv) })
        layouts[text] = layout
        return layout
    }
}
