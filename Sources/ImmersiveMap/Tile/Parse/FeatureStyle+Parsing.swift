// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// What the parser bakes of a style into a tile's style table: the colours
/// of one stroke or fill and its line parameters, keyed by the style's key.
/// A fill is baked as a stroke of the fill's colour on the standard fill
/// ribbon width.
struct BakedStyle {
    let pass: LinePass

    /// The ribbon width every fill is baked with: the edge threshold it
    /// yields is what the fill shaders have always read.
    static let fillRibbonWidth: Double = 100

    init(pass: LinePass) {
        self.pass = pass
    }

    init(fill: FillStyle) {
        self.pass = LinePass(key: fill.key,
                             color: fill.color,
                             zoomFade: fill.zoomFade,
                             lineGeometry: LineGeometryStyle(lineWidth: Self.fillRibbonWidth))
    }

    init(extrusion: ExtrusionStyle) {
        self.pass = LinePass(key: extrusion.key,
                             color: extrusion.color,
                             lineGeometry: LineGeometryStyle(lineWidth: Self.fillRibbonWidth))
    }

    var color: SIMD4<Float> { pass.color }
    /// The pair the tile shaders read for the style's zoom fade.
    var zoomFade: SIMD2<Float> { pass.zoomFade.shaderPair }
}
