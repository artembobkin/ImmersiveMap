// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the flat road drawer reads of a road layer's styles to choose the
/// layer's pass each frame: an opaque layer writes its rank with blending
/// off, a layer with anything else in it blends (the road ribbons in
/// Tile.metal). Read once from the layer's style tables when the tile's
/// buffers are built.
struct RoadLayerStyles {
    struct Style {
        /// The colour carries alpha 1.
        let isAlphaOpaque: Bool
        /// The pair `tileStyleFade` reads.
        let zoomFade: SIMD2<Float>
        /// The width ramp's alpha: `startAlpha` up to `startZoom`, one from
        /// `endZoom`. An end zoom not past the start is no ramp.
        let rampStartAlpha: Float
        let rampStartZoom: Float
        let rampEndZoom: Float
        /// The style cuts a dash pattern per fragment.
        let isDashed: Bool

        func isOpaque(overviewFade: TileOverviewFadeUniform) -> Bool {
            isAlphaOpaque
                && isDashed == false
                && rampAlphaIsOne(cameraZoom: overviewFade.cameraZoom)
                && TileStyleFadeMath.fadeIsOne(zoomFade: zoomFade, overviewFade: overviewFade)
        }

        func isInvisible(overviewFade: TileOverviewFadeUniform) -> Bool {
            TileStyleFadeMath.fadeIsZero(zoomFade: zoomFade, overviewFade: overviewFade)
        }

        private func rampAlphaIsOne(cameraZoom: Float) -> Bool {
            rampStartAlpha >= 1 || rampEndZoom <= rampStartZoom || cameraZoom >= rampEndZoom
        }
    }

    enum Pass {
        /// Nothing of the layer shows this frame.
        case hidden
        /// Every style is opaque this frame.
        case opaque
        /// Some style is translucent, fading or dashed.
        case blended
    }

    let styles: [Style]

    static let empty = RoadLayerStyles(styles: [])

    func pass(overviewFade: TileOverviewFadeUniform) -> Pass {
        guard styles.isEmpty == false else { return .blended }
        if styles.allSatisfy({ $0.isInvisible(overviewFade: overviewFade) }) {
            return .hidden
        }
        return styles.allSatisfy { $0.isOpaque(overviewFade: overviewFade) } ? .opaque : .blended
    }

    /// Reads the three style tables of a layer, lockstep by style index. A
    /// layer whose tables do not line up reads as empty, which blends.
    init(styles: TileBufferView?, styleZoomFades: TileBufferView?, lineStyles: TileBufferView?) {
        guard let styles, let styleZoomFades, let lineStyles,
              styles.count == styleZoomFades.count, styles.count == lineStyles.count else {
            self.styles = []
            return
        }
        let colors = styles.buffer.contents().advanced(by: styles.offset)
        let fades = styleZoomFades.buffer.contents().advanced(by: styleZoomFades.offset)
        let lines = lineStyles.buffer.contents().advanced(by: lineStyles.offset)
        self.styles = (0 ..< styles.count).map { index in
            let color = colors.loadUnaligned(fromByteOffset: index * MemoryLayout<TilePolygonStyle>.stride,
                                             as: TilePolygonStyle.self)
            let fade = fades.loadUnaligned(fromByteOffset: index * MemoryLayout<SIMD2<Float>>.stride,
                                           as: SIMD2<Float>.self)
            let line = lines.loadUnaligned(fromByteOffset: index * MemoryLayout<TileLineStyle>.stride,
                                           as: TileLineStyle.self)
            return Style(isAlphaOpaque: color.color.w >= 1,
                         zoomFade: fade,
                         rampStartAlpha: line.rampStartAlpha,
                         rampStartZoom: line.rampStartZoom,
                         rampEndZoom: line.rampEndZoom,
                         isDashed: line.dashLengthPoints > 0)
        }
    }

    init(styles: [Style]) {
        self.styles = styles
    }
}
